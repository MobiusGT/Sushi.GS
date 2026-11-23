import Foundation

public struct EpisodeKey: Hashable, Comparable, Sendable {
    public var season: Int?
    public var episode: Double
    public var specialTag: String?

    public init(season: Int? = nil, episode: Double, specialTag: String? = nil) {
        self.season = season
        self.episode = episode
        self.specialTag = specialTag
    }

    public var displayBadge: String {
        let epStr = episode.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%02d", Int(episode))
            : String(format: "%.1f", episode)
        if let specialTag {
            return "\(specialTag.uppercased()) \(epStr)"
        }
        if let season {
            return String(format: "S%02dE%@", season, epStr)
        }
        return "EP \(epStr)"
    }

    public static func < (lhs: EpisodeKey, rhs: EpisodeKey) -> Bool {
        let ls = lhs.season ?? 0
        let rs = rhs.season ?? 0
        if ls != rs { return ls < rs }
        let ltag = lhs.specialTag ?? ""
        let rtag = rhs.specialTag ?? ""
        if ltag != rtag { return ltag < rtag }
        return lhs.episode < rhs.episode
    }
}

/// How a Source -> Target episode pair was matched.
public enum PairMatchKind: String, Codable, Hashable, Sendable {
    /// Tier 1: Exact filename or exact filename stem ignoring container extension (auto-verified).
    case exactFilename
    /// Tier 2: Normalized episode-number match with differing filenames (starts unverified).
    case episodeRegex
    /// Tier 3: Conservative normalized-title similarity fallback for non-numbered specials (starts unverified).
    case titleSimilarity
    /// Unmatched entry ("No match found" on the missing side; starts unverified).
    case unmatched
}

public struct PairedEpisodeDraft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var episodeKey: EpisodeKey?
    public var sourceFile: URL?
    public var targetFile: URL?
    public var externalSubtitleFile: URL?
    public var matchKind: PairMatchKind
    public var isVerified: Bool

    /// True for Tier 1 exact-name or Tier 2 episode-number matches.
    public var isExactMatch: Bool {
        matchKind == .exactFilename || matchKind == .episodeRegex
    }

    public init(
        id: UUID = UUID(),
        episodeKey: EpisodeKey? = nil,
        sourceFile: URL? = nil,
        targetFile: URL? = nil,
        externalSubtitleFile: URL? = nil,
        matchKind: PairMatchKind = .episodeRegex,
        isVerified: Bool? = nil
    ) {
        self.id = id
        self.episodeKey = episodeKey
        self.sourceFile = sourceFile
        self.targetFile = targetFile
        self.externalSubtitleFile = externalSubtitleFile
        self.matchKind = matchKind
        self.isVerified = isVerified ?? (matchKind == .exactFilename)
    }
}

/// Multi-tier episode matcher for anime and TV release filenames.
///
/// Cascade:
/// - Strict Season Mismatch Rule across all tiers: differing explicit seasons NEVER match.
/// - Tier 1: Exact filename or exact filename stem ignoring extension -> auto-Verified.
/// - Tier 2: Noise-stripped normalized episode number matching (`S##E##` priority, `1x05`,
///           leading-zero & `v2` version normalization, fractional specials) -> Unverified.
/// - Tier 3: Conservative normalized-title similarity fallback for non-numbered specials
///           (`OVA`, `Movie`, `NCOP`, `NCED`, `Special`) -> Unverified.
/// - Otherwise leaves entries explicitly unpaired (`matchKind == .unmatched`) rather than forcing bad matches.
public enum EpisodePairing {
    public static let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "webm", "m4v", "mov"]
    public static let audioExtensions: Set<String> = ["flac", "wav", "aac", "ac3", "eac3", "m4a", "mp3", "opus", "pcm", "mka"]
    public static let subtitleExtensions: Set<String> = ["ass", "ssa", "srt"]
    public static let mediaExtensions: Set<String> = videoExtensions.union(audioExtensions)

    private static let noisePatterns: [String] = [
        #"[\[\(][0-9A-Fa-f]{8}[\]\)]"#,                                                        // CRC32 tags [A1B2C3D4]
        #"\b(?:2160|1080|720|576|480)[pi]\b"#,                                                 // Video resolution
        #"\b(?:4K|UHD|FHD|HD)\b"#,                                                             // Resolution shorthands
        #"\b(?:x|h)\.?26[45]\b"#,                                                              // x264 / H.265
        #"\b(?:hevc|avc|av1|vp9|xvid|divx|mpeg2)\b"#,                                          // Video codecs
        #"\b(?:10|8|12)[\s\-]?bit\b"#,                                                         // Bit depth
        #"\b(?:e-?ac-?3|aac|ac3|ddp|dd\+|dts(?:-?hd)?|truehd|atmos|flac|opus|mp3|l?pcm)(?:[\s\.\-_]*\d(?:\.\d)?)?(?=$|[\s\.\-_\]\)])"#, // Audio codecs
        #"\b[257]\.[01]\b"#,                                                                   // Channel layouts 5.1 / 2.0
        #"[\(\[](?:19|20)\d{2}[\)\]]"#,                                                        // Release year (2024)
        #"\b(?:web-?dl|web-?rip|blu-?ray|bd-?rip|bd-?remux|remux|bd|dvd-?rip|hdtv|dual[\s\.\-_]?audio|multi[\s\.\-_]?subs?|repack|proper|uncensored|amzn|nf|cr|hidive|funimation)\b"#,
        #"\bv[0-4]\b"#,                                                                        // Standalone v2
    ]

    /// Distinct special categories that must not cross-match each other in Tier 3 title similarity.
    private static let specialCategoryMap: [String: String] = [
        "ova": "ova", "oad": "ova",
        "ncop": "ncop", "creditlessop": "ncop",
        "nced": "nced", "creditlessed": "nced",
        "movie": "movie", "film": "movie", "theatrical": "movie",
        "special": "special", "sp": "special", "extra": "special", "omake": "special",
        "pv": "promo", "cm": "promo", "trailer": "promo", "teaser": "promo",
    ]

    private static let titleStopWords: Set<String> = [
        "the", "a", "an", "of", "and", "to", "in", "on", "at", "for", "with",
        "v1", "v2", "v3", "v4", "eng", "jpn", "jap", "sub", "subs", "dub", "raw",
    ]

    /// True when two explicit season numbers disagree. If either side omits a season, returns false.
    public static func seasonsConflict(_ lhs: Int?, _ rhs: Int?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }

    /// True when two media files have the exact same filename or exact same filename stem
    /// ignoring container extension (e.g. `Show - 01.mkv` and `Show - 01.mp4`).
    public static func isExactFilenameMatch(source: URL, target: URL) -> Bool {
        let srcName = source.lastPathComponent
        let dstName = target.lastPathComponent
        if srcName.caseInsensitiveCompare(dstName) == .orderedSame {
            return true
        }
        let srcStem = source.deletingPathExtension().lastPathComponent
        let dstStem = target.deletingPathExtension().lastPathComponent
        return !srcStem.isEmpty && srcStem.caseInsensitiveCompare(dstStem) == .orderedSame
    }

    public static func sanitizeFilename(_ filename: String) -> String {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        var cleaned = stem

        // Strip version suffixes attached directly to episode numbers (e.g. `01v2` -> `01`, `S01E05v2` -> `S01E05`, `12.5v2` -> `12.5`).
        cleaned = replaceRegex(#"(?i)(\d{1,3}(?:\.\d)?)v[1-9]\b"#, in: cleaned, with: "$1")

        for pattern in noisePatterns {
            cleaned = replaceRegex("(?i)\(pattern)", in: cleaned, with: " ")
        }
        return cleaned
    }

    /// Extracts an explicit season number if present (`S01E05`, `1x05`, `Season 2`, `S02`).
    public static func extractSeason(from filename: String) -> Int? {
        let cleaned = sanitizeFilename(filename)

        if let m = firstMatch(#"(?i)\bS(\d{1,2})\s*[\.\-_]?\s*E\d{1,3}(?:\.\d)?\b"#, in: cleaned),
           let s = Int(m[1]) {
            return s
        }
        if let m = firstMatch(#"(?i)\b(\d{1,2})x\d{1,3}(?:\.\d)?\b"#, in: cleaned),
           let s = Int(m[1]) {
            return s
        }
        if let m = firstMatch(#"(?i)\bSeason[\s\.\-_]*(\d{1,2})\b"#, in: cleaned),
           let s = Int(m[1]) {
            return s
        }
        if let m = firstMatch(#"(?i)(?:^|[\s\.\-_(\[])S(\d{1,2})(?=$|[\s\.\-_)\]])"#, in: cleaned),
           let s = Int(m[1]) {
            return s
        }
        return nil
    }

    /// Extracts normalized `(season, episode, specialTag)` from a media or subtitle filename.
    /// Leading zeroes and version suffixes (`005` -> `5`, `01v2` -> `1`, `01.5` -> `1.5`) are normalized automatically.
    public static func extractEpisodeKey(from filename: String) -> EpisodeKey? {
        let cleaned = sanitizeFilename(filename)

        // 1. S##E## priority (e.g. S01E05, S1E5, S01E005, S01E12.5, S01.E05)
        if let m = firstMatch(#"(?i)\bS(\d{1,2})\s*[\.\-_]?\s*E(\d{1,3}(?:\.\d)?)\b"#, in: cleaned),
           let s = Int(m[1]), let e = Double(m[2]) {
            return EpisodeKey(season: s, episode: e)
        }

        // 2. 1x05 / 02x12.5
        if let m = firstMatch(#"(?i)\b(\d{1,2})x(\d{1,3}(?:\.\d)?)\b"#, in: cleaned),
           let s = Int(m[1]), let e = Double(m[2]) {
            return EpisodeKey(season: s, episode: e)
        }

        // Capture any standalone season token (e.g. "Season 2" or "S02") and strip it
        // so standalone-number rules below never mistake "Season 2" for Episode 2.
        let explicitSeason = extractSeason(from: filename)
        var epSearchText = cleaned
        epSearchText = replaceRegex(#"(?i)\bSeason[\s\.\-_]*\d{1,2}\b"#, in: epSearchText, with: " ")
        epSearchText = replaceRegex(#"(?i)(?:^|[\s\.\-_(\[])S\d{1,2}(?=$|[\s\.\-_)\]])"#, in: epSearchText, with: " ")

        // 3. Numbered Specials / OVA / OAD / SP / Special / NCOP / NCED
        if let m = firstMatch(#"(?i)\b(OVA|OAD|SP|Special|NCOP|NCED)[\s\.\-_#]*(\d{1,2}(?:\.\d)?)\b"#, in: epSearchText),
           let e = Double(m[2]) {
            let tag = m[1].uppercased() == "SPECIAL" ? "SP" : m[1].uppercased()
            return EpisodeKey(season: explicitSeason, episode: e, specialTag: tag)
        }

        // 4. Explicit episode prefix: Episode 5 / Ep.05 / EP05 / E05
        if let m = firstMatch(#"(?i)\b(?:Episode|Ep\.?|E)[\s\.\-_#]*(\d{1,3}(?:\.\d)?)\b"#, in: epSearchText),
           let e = Double(m[1]) {
            return EpisodeKey(season: explicitSeason, episode: e)
        }

        // 5. Fansub dash pattern: " - 05 " / " - 5 " / " - 01.5 " / " - 05 ["
        if let m = firstMatch(#"(?:\s+-\s+|\s+–\s+)(\d{1,3}(?:\.\d)?)(?=\s|$|[\[\(\-_\.])"#, in: epSearchText),
           let e = Double(m[1]) {
            return EpisodeKey(season: explicitSeason, episode: e)
        }

        // 6. Bracketed episode number: [05] or (05)
        if let m = firstMatch(#"[\[\(](\d{1,3}(?:\.\d)?)[\]\)]"#, in: epSearchText),
           let e = Double(m[1]) {
            return EpisodeKey(season: explicitSeason, episode: e)
        }

        // 7. Hash or underscored episode number: #05 or _05_
        if let m = firstMatch(#"(?:#|_)(\d{1,3}(?:\.\d)?)(?=\b|_|\s|$)"#, in: epSearchText),
           let e = Double(m[1]) {
            return EpisodeKey(season: explicitSeason, episode: e)
        }

        // 8. Trailing standalone episode number at end of cleaned title (e.g. "Show Name 05" or "Show.Name.5")
        if let m = firstMatch(#"(?:^|[\s\.\-_])(\d{1,3}(?:\.\d)?)\s*$"#, in: epSearchText),
           let e = Double(m[1]), e < 1900 {
            return EpisodeKey(season: explicitSeason, episode: e)
        }

        return nil
    }

    /// Normalized alphanumeric title tokens (release group brackets & media noise stripped)
    /// used for tie-breaking and Tier 3 conservative special matching.
    public static func normalizedTitleTokens(from filename: String) -> Set<String> {
        var text = sanitizeFilename(filename)
        // Strip leading release-group bracket e.g. `[SubsPlease]` or `(Group)`
        text = replaceRegex(#"^\s*[\[\(][^\]\)]+[\]\)]\s*"#, in: text, with: " ")
        // Strip explicit season/episode tags so title comparison focuses on title + special words
        text = replaceRegex(#"(?i)\bS\d{1,2}\s*[\.\-_]?\s*E\d{1,3}(?:\.\d)?\b"#, in: text, with: " ")
        text = replaceRegex(#"(?i)\bSeason[\s\.\-_]*\d{1,2}\b"#, in: text, with: " ")
        text = replaceRegex(#"(?i)(?:^|[\s\.\-_])S\d{1,2}(?=$|[\s\.\-_])"#, in: text, with: " ")

        let rawTokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !titleStopWords.contains($0) }

        return Set(rawTokens)
    }

    public static func titleSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        guard intersection > 0 else { return 0 }
        let union = lhs.union(rhs).count
        return Double(intersection) / Double(union)
    }

    private static func specialCategories(in tokens: Set<String>) -> Set<String> {
        var cats: Set<String> = []
        for token in tokens {
            if let cat = specialCategoryMap[token] {
                cats.insert(cat)
            }
        }
        return cats
    }

    private struct FileMetadata {
        let url: URL
        let stemLower: String
        let season: Int?
        let episodeKey: EpisodeKey?
        let titleTokens: Set<String>
        let specialCats: Set<String>

        init(url: URL) {
            self.url = url
            self.stemLower = url.deletingPathExtension().lastPathComponent.lowercased()
            let key = EpisodePairing.extractEpisodeKey(from: url.lastPathComponent)
            self.episodeKey = key
            self.season = key?.season ?? EpisodePairing.extractSeason(from: url.lastPathComponent)
            let tokens = EpisodePairing.normalizedTitleTokens(from: url.lastPathComponent)
            self.titleTokens = tokens
            self.specialCats = EpisodePairing.specialCategories(in: tokens)
        }
    }

    public static func pairFiles(
        sources: [URL],
        targets: [URL],
        externalSubtitles: [URL] = []
    ) -> [PairedEpisodeDraft] {
        let sortedSources = sources.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let sortedTargets = targets.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let sortedSubs = externalSubtitles.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        let sourceMeta = sortedSources.map(FileMetadata.init(url:))
        let targetMeta = sortedTargets.map(FileMetadata.init(url:))
        let subMeta = sortedSubs.map(FileMetadata.init(url:))

        var usedTargets: Set<URL> = []
        var usedSubs: Set<URL> = []
        var drafts: [PairedEpisodeDraft] = []

        func claimSub(for src: FileMetadata) -> URL? {
            if let exact = subMeta.first(where: { !usedSubs.contains($0.url) && $0.stemLower == src.stemLower }) {
                usedSubs.insert(exact.url)
                return exact.url
            }
            if let srcKey = src.episodeKey {
                // Exact season + episode + specialTag subtitle match first
                if let exactKey = subMeta.first(where: {
                    !usedSubs.contains($0.url)
                        && $0.episodeKey == srcKey
                        && !seasonsConflict(src.season, $0.season)
                }) {
                    usedSubs.insert(exactKey.url)
                    return exactKey.url
                }
                // Episode match with non-conflicting season
                if let epMatch = subMeta.first(where: {
                    !usedSubs.contains($0.url)
                        && $0.episodeKey?.episode == srcKey.episode
                        && $0.episodeKey?.specialTag == srcKey.specialTag
                        && !seasonsConflict(src.season, $0.season)
                }) {
                    usedSubs.insert(epMatch.url)
                    return epMatch.url
                }
            }
            return nil
        }

        // MARK: Tier 1 — Exact filename or exact filename stem ignoring container extension (Auto-Verified)
        var afterTier1: [FileMetadata] = []
        for src in sourceMeta {
            if let dst = targetMeta.first(where: {
                !usedTargets.contains($0.url) && isExactFilenameMatch(source: src.url, target: $0.url)
            }) {
                usedTargets.insert(dst.url)
                drafts.append(
                    PairedEpisodeDraft(
                        episodeKey: src.episodeKey ?? dst.episodeKey,
                        sourceFile: src.url,
                        targetFile: dst.url,
                        externalSubtitleFile: claimSub(for: src),
                        matchKind: .exactFilename,
                        isVerified: true
                    )
                )
            } else {
                afterTier1.append(src)
            }
        }

        // MARK: Tier 2a — Both sides have explicit matching season + normalized episode number (Unverified)
        var afterTier2a: [FileMetadata] = []
        for src in afterTier1 {
            guard let srcKey = src.episodeKey, let srcSeason = src.season else {
                afterTier2a.append(src)
                continue
            }
            let candidates = targetMeta.filter { dst in
                guard !usedTargets.contains(dst.url),
                      let dstKey = dst.episodeKey,
                      let dstSeason = dst.season else { return false }
                return srcSeason == dstSeason
                    && srcKey.episode == dstKey.episode
                    && srcKey.specialTag == dstKey.specialTag
            }
            if let best = bestByTitleSimilarity(for: src, among: candidates) {
                usedTargets.insert(best.url)
                drafts.append(
                    PairedEpisodeDraft(
                        episodeKey: srcKey,
                        sourceFile: src.url,
                        targetFile: best.url,
                        externalSubtitleFile: claimSub(for: src),
                        matchKind: .episodeRegex,
                        isVerified: false
                    )
                )
            } else {
                afterTier2a.append(src)
            }
        }

        // MARK: Tier 2b — Normalized episode number matching where at most one side specifies a season
        // Strictly enforces seasonsConflict(src.season, dst.season) == false.
        var afterTier2b: [FileMetadata] = []
        for src in afterTier2a {
            guard let srcKey = src.episodeKey else {
                afterTier2b.append(src)
                continue
            }
            let candidates = targetMeta.filter { dst in
                guard !usedTargets.contains(dst.url),
                      let dstKey = dst.episodeKey else { return false }
                guard !seasonsConflict(src.season, dst.season) else { return false }
                return srcKey.episode == dstKey.episode
                    && srcKey.specialTag == dstKey.specialTag
            }
            if let best = bestByTitleSimilarity(for: src, among: candidates) {
                usedTargets.insert(best.url)
                let mergedKey = EpisodeKey(
                    season: src.season ?? best.season,
                    episode: srcKey.episode,
                    specialTag: srcKey.specialTag
                )
                drafts.append(
                    PairedEpisodeDraft(
                        episodeKey: mergedKey,
                        sourceFile: src.url,
                        targetFile: best.url,
                        externalSubtitleFile: claimSub(for: src),
                        matchKind: .episodeRegex,
                        isVerified: false
                    )
                )
            } else {
                afterTier2b.append(src)
            }
        }

        // MARK: Tier 3 — Conservative normalized-title similarity fallback for non-numbered specials
        // Never overrides differing episode numbers or differing explicit seasons.
        var unmatchedSources: [FileMetadata] = []
        for src in afterTier2b {
            guard src.episodeKey == nil else {
                unmatchedSources.append(src)
                continue
            }
            let candidates = targetMeta.filter { dst in
                guard !usedTargets.contains(dst.url),
                      dst.episodeKey == nil,
                      !seasonsConflict(src.season, dst.season) else { return false }
                // Reject conflicting special types (e.g. NCOP vs NCED, OVA vs Movie)
                if !src.specialCats.isEmpty && !dst.specialCats.isEmpty && src.specialCats.isDisjoint(with: dst.specialCats) {
                    return false
                }
                return titleSimilarity(src.titleTokens, dst.titleTokens) >= 0.60
            }

            if let best = candidates.max(by: {
                let s1 = titleSimilarity(src.titleTokens, $0.titleTokens)
                let s2 = titleSimilarity(src.titleTokens, $1.titleTokens)
                if s1 != s2 { return s1 < s2 }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedDescending
            }) {
                usedTargets.insert(best.url)
                drafts.append(
                    PairedEpisodeDraft(
                        episodeKey: nil,
                        sourceFile: src.url,
                        targetFile: best.url,
                        externalSubtitleFile: claimSub(for: src),
                        matchKind: .titleSimilarity,
                        isVerified: false
                    )
                )
            } else {
                unmatchedSources.append(src)
            }
        }

        // MARK: Explicit Unmatched ("No match found") — Never force bad positional pairings
        for src in unmatchedSources {
            drafts.append(
                PairedEpisodeDraft(
                    episodeKey: src.episodeKey,
                    sourceFile: src.url,
                    targetFile: nil,
                    externalSubtitleFile: claimSub(for: src),
                    matchKind: .unmatched,
                    isVerified: false
                )
            )
        }

        for dst in targetMeta where !usedTargets.contains(dst.url) {
            drafts.append(
                PairedEpisodeDraft(
                    episodeKey: dst.episodeKey,
                    sourceFile: nil,
                    targetFile: dst.url,
                    externalSubtitleFile: nil,
                    matchKind: .unmatched,
                    isVerified: false
                )
            )
        }

        return drafts.sorted { lhs, rhs in
            switch (lhs.episodeKey, rhs.episodeKey) {
            case let (l?, r?):
                if l != r { return l < r }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            let lName = lhs.sourceFile?.lastPathComponent ?? lhs.targetFile?.lastPathComponent ?? ""
            let rName = rhs.sourceFile?.lastPathComponent ?? rhs.targetFile?.lastPathComponent ?? ""
            return lName.localizedStandardCompare(rName) == .orderedAscending
        }
    }

    private static func bestByTitleSimilarity(for src: FileMetadata, among candidates: [FileMetadata]) -> FileMetadata? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        return candidates.max { lhs, rhs in
            let s1 = titleSimilarity(src.titleTokens, lhs.titleTokens)
            let s2 = titleSimilarity(src.titleTokens, rhs.titleTokens)
            if s1 != s2 { return s1 < s2 }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedDescending
        }
    }

    public static func scanMediaFiles(in directory: URL) -> (media: [URL], subtitles: [URL]) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        var media: [URL] = []
        var subs: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.pathComponents.contains("Merged Files") {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            if mediaExtensions.contains(ext) {
                media.append(fileURL)
            } else if subtitleExtensions.contains(ext), !fileURL.lastPathComponent.contains(".sushi.") {
                subs.append(fileURL)
            }
        }
        return (media, subs)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { idx in
            let r = match.range(at: idx)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }

    private static func replaceRegex(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
