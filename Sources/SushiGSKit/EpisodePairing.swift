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

/// Subtitle intake mode shared by Auto Batch and Manual Batch workspaces.
public enum BatchSubtitleMode: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case embedded
    case external

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .embedded: "Embedded"
        case .external: "External"
        }
    }
}

/// How a Source -> Target (and optional External Subtitle) episode pair was matched.
public enum PairMatchKind: String, Codable, Hashable, Sendable {
    /// Tier 1: Exact filename or exact filename stem ignoring container extension (auto-verified).
    case exactFilename
    /// Tier 2: Normalized episode-number match with differing filenames (starts unverified).
    case episodeRegex
    /// Tier 3: Conservative normalized-title similarity fallback for non-numbered specials (starts unverified).
    case titleSimilarity
    /// Unmatched entry ("No match found" on one or more required sides; starts unverified).
    case unmatched

    fileprivate var tierRank: Int {
        switch self {
        case .exactFilename: 0
        case .episodeRegex: 1
        case .titleSimilarity: 2
        case .unmatched: 3
        }
    }

    static func combined(_ lhs: PairMatchKind, _ rhs: PairMatchKind) -> PairMatchKind {
        lhs.tierRank >= rhs.tierRank ? lhs : rhs
    }
}

public struct PairedEpisodeDraft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var episodeKey: EpisodeKey?
    public var sourceFile: URL?
    public var targetFile: URL?
    public var externalSubtitleFile: URL?
    public var matchKind: PairMatchKind
    public var subtitleMatchKind: PairMatchKind?
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
        subtitleMatchKind: PairMatchKind? = nil,
        isVerified: Bool? = nil
    ) {
        self.id = id
        self.episodeKey = episodeKey
        self.sourceFile = sourceFile
        self.targetFile = targetFile
        self.externalSubtitleFile = externalSubtitleFile
        self.matchKind = matchKind
        self.subtitleMatchKind = subtitleMatchKind
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
    public static let subtitleExtensions: Set<String> = ["ass", "ssa", "srt", "sub", "vtt"]
    public static let mediaExtensions: Set<String> = videoExtensions.union(audioExtensions)

    private static let noisePatterns: [String] = [
        #"[\[\(][0-9A-Fa-f]{8}[\]\)]"#,                                                        // CRC32 tags [A1B2C3D4]
        #"\b\d{3,4}x\d{3,4}\b"#,                                                               // Pixel dimensions 1920x1080
        #"\b(?:2160|1080|720|576|480)[pi]\b"#,                                                 // Video resolution
        #"\b(?:4K|UHD|FHD|HD)\b"#,                                                             // Resolution shorthands
        #"\b(?:x|h)\.?26[45]\b"#,                                                              // x264 / H.265
        #"\b(?:hevc|avc|av1|vp9|xvid|divx|mpeg2)\b"#,                                          // Video codecs
        #"\b(?:8|10|12|16|24)[\s\-]?bit\b"#,                                                   // Bit depth
        #"\b(?:e-?ac-?3|aac|ac3|ddp|dd\+|dts(?:-?hd)?|truehd|atmos|flac|opus|mp3|l?pcm)(?:[\s\.\-_]*\d(?:\.\d)?)?(?=$|[\s\.\-_\]\)])"#, // Audio codecs
        #"(?<![A-Za-z0-9])[257]\.[01](?![A-Za-z0-9])"#,                                        // Channel layouts 5.1 / 2.0
        #"[\(\[](?:19|20)\d{2}[\)\]]"#,                                                        // Release year (2024)
        #"\b(?:web-?dl|web-?rip|blu-?ray|bd-?rip|bd-?remux|bdmv|remux|bd|dvd-?rip|dvd|hdtv|dual[\s\.\-_]?audio|multi[\s\.\-_]?subs?|repack|proper|uncensored|amzn|nf|cr|hidive|funimation)\b"#,
        #"(?<![A-Za-z0-9])track[\s\.\-_#]*\d+(?![A-Za-z0-9])"#,                                // Extracted subtitle track suffixes (track3 / Track 2)
        #"(?<![A-Za-z0-9])(?:v[0-9]|rev\d+)(?![A-Za-z0-9])"#,                                  // Standalone v2 / rev2
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
        // Normalize fullwidth digits (０–９) to ASCII digits without altering Japanese Kana/Kanji.
        var cleaned = String(String.UnicodeScalarView(stem.unicodeScalars.map { scalar -> UnicodeScalar in
            if scalar.value >= 0xFF10 && scalar.value <= 0xFF19 {
                return UnicodeScalar(scalar.value - 0xFF10 + 0x30) ?? scalar
            }
            return scalar
        }))

        // Strip version suffixes attached directly to episode numbers (e.g. `01v2` -> `01`, `00001v2` -> `00001`, `S01E05v2` -> `S01E05`, `12.5v2` -> `12.5`).
        cleaned = replaceRegex(#"(?i)(?<!\d)(0*\d{1,4}(?:\.\d)?)v[1-9]\b"#, in: cleaned, with: "$1")

        // Strip release-group and technical metadata brackets BEFORE token-level noise stripping
        // so blocks like `[Moozzi2]`, `[Stardust]`, `【Stardust】`, `(BD Remux 1080p)`, `(DVD 2)`, `[A1B2C3D4]`, `(1990)`
        // are removed whole without leaving orphaned digits inside brackets.
        cleaned = stripNonEpisodeBrackets(from: cleaned)

        for pattern in noisePatterns {
            cleaned = replaceRegex("(?i)\(pattern)", in: cleaned, with: " ")
        }
        return cleaned
    }

    /// Parses an arbitrarily zero-padded episode token (e.g. `00001` -> `1`, `01.5` -> `1.5`),
    /// stripping leading zeroes before numeric bounds checks while rejecting unpadded 4-digit years
    /// (`1900`–`2099`) and out-of-range IDs/dates.
    private static func parseEpisodeNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let intPart = String(parts[0])
        guard !intPart.isEmpty, intPart.allSatisfy(\.isNumber) else { return nil }

        let hasLeadingZero = intPart.count > 1 && intPart.hasPrefix("0")
        let strippedInt = String(intPart.drop(while: { $0 == "0" }))
        let normalizedInt = strippedInt.isEmpty ? "0" : strippedInt

        let normalized: String
        if parts.count == 2 {
            let fracPart = String(parts[1])
            guard fracPart.count == 1, fracPart.allSatisfy(\.isNumber) else { return nil }
            normalized = "\(normalizedInt).\(fracPart)"
        } else {
            normalized = normalizedInt
        }

        guard let value = Double(normalized), value.isFinite else { return nil }
        guard value >= 0, value <= 1999 else { return nil }
        // Reject unpadded 4-digit release years (e.g. 1990–2099), while always accepting zero-padded BDMV numbers (e.g. 00001).
        if !hasLeadingZero && intPart.count == 4 && value >= 1900 && value <= 2099 {
            return nil
        }
        return value
    }

    /// Removes bracketed/parenthesized release-group and technical metadata blocks (e.g. `[Moozzi2]`,
    /// `[Stardust]`, `【Stardust】`, `(BD Remux 1080p)`, `(DVD)`, `[1080p FLAC]`, `(rev2)`) while preserving pure
    /// numeric episode brackets (`[01]`, `[00001]`, `(05)`) and explicit season/episode/special brackets.
    private static func stripNonEpisodeBrackets(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[[^\[\]]*\]|\([^\(\)]*\)|【[^【】]*】|（[^（）]*）"#) else {
            return text
        }

        var result = text
        for _ in 0..<3 {
            let nsText = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsText.length))
            guard !matches.isEmpty else { break }

            var changed = false
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let block = String(result[range])
                let inner = String(block.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)

                if shouldPreserveBracketContent(inner) {
                    continue
                }
                result.replaceSubrange(range, with: " ")
                changed = true
            }
            if !changed { break }
        }
        return result
    }

    private static func shouldPreserveBracketContent(_ inner: String) -> Bool {
        guard !inner.isEmpty else { return false }
        // Never preserve 8-hex CRC32 tags even if all-digit (e.g. [11223344])
        if firstMatch(#"^[0-9A-Fa-f]{8}$"#, in: inner) != nil {
            return false
        }
        // Preserve pure numeric brackets like [01], (05), [00001], [12.5]
        if firstMatch(#"^0*\d{1,4}(?:\.\d)?$"#, in: inner) != nil, parseEpisodeNumber(inner) != nil {
            return true
        }
        // Preserve explicit S##E##, 1x##, Season ##, EP##, Episode ##, or special labels
        if firstMatch(#"(?i)\bS\d{1,2}\s*[\.\-_]?\s*E0*\d{1,4}(?:\.\d)?\b"#, in: inner) != nil { return true }
        if firstMatch(#"(?i)\b\d{1,2}x0*\d{1,4}(?:\.\d)?\b"#, in: inner) != nil { return true }
        if firstMatch(#"(?i)\bSeason[\s\.\-_]*\d{1,2}\b"#, in: inner) != nil { return true }
        if firstMatch(#"(?i)^S\d{1,2}$"#, in: inner) != nil { return true }
        if firstMatch(#"(?i)^(?:Episode|Ep\.?|E)[\s\.\-_#]*0*\d{1,4}(?:\.\d)?$"#, in: inner) != nil { return true }
        if firstMatch(#"(?i)^(OVA|OAD|SP|Special|NCOP|NCED|Movie|Film)(?:[\s\.\-_#]*0*\d{1,4}(?:\.\d)?)?$"#, in: inner) != nil { return true }
        return false
    }

    /// Extracts an explicit season number if present (`S01E05`, `1x05`, `Season 2`, `S02`).
    public static func extractSeason(from filename: String) -> Int? {
        let cleaned = sanitizeFilename(filename)

        if let m = firstMatch(#"(?i)\bS(\d{1,2})\s*[\.\-_]?\s*E0*\d{1,4}(?:\.\d)?(?!\d)"#, in: cleaned),
           let s = Int(m[1]) {
            return s
        }
        if let m = firstMatch(#"(?i)\b(\d{1,2})x0*\d{1,4}(?:\.\d)?(?!\d)"#, in: cleaned),
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
    /// Arbitrarily zero-padded BDMV numbers (`00001` -> `1`), leading zeroes (`005` -> `5`),
    /// version suffixes (`01v2` -> `1`), and fractional specials (`01.5` -> `1.5`) are normalized automatically.
    public static func extractEpisodeKey(from filename: String) -> EpisodeKey? {
        let cleaned = sanitizeFilename(filename)

        // 1. S##E## priority (e.g. S01E05, S1E5, S01E005, S01E00005, S01E12.5, S01.E05)
        if let m = firstMatch(#"(?i)\bS(\d{1,2})\s*[\.\-_]?\s*E(0*\d{1,4}(?:\.\d)?)(?!\d)"#, in: cleaned),
           let s = Int(m[1]), let e = parseEpisodeNumber(m[2]) {
            return EpisodeKey(season: s, episode: e)
        }

        // 2. 1x05 / 02x12.5 / 01x00005
        if let m = firstMatch(#"(?i)\b(\d{1,2})x(0*\d{1,4}(?:\.\d)?)(?!\d)"#, in: cleaned),
           let s = Int(m[1]), let e = parseEpisodeNumber(m[2]) {
            return EpisodeKey(season: s, episode: e)
        }

        // Capture any standalone season token (e.g. "Season 2" or "S02") and strip it before episode lookup
        // so season digits never get mistaken for episode numbers.
        let explicitSeason = extractSeason(from: filename)
        var epSearchText = cleaned
        epSearchText = replaceRegex(#"(?i)\bSeason[\s\.\-_]*\d{1,2}\b"#, in: epSearchText, with: " ")
        epSearchText = replaceRegex(#"(?i)(?:^|[\s\.\-_(\[])S\d{1,2}(?=$|[\s\.\-_)\]])"#, in: epSearchText, with: " ")

        // 3. Numbered Specials / Extras (OVA / OAD / SP / Special / NCOP / NCED / Menu / PV / CM / OP / ED / Bonus)
        for m in allMatches(#"(?i)\b(OVA|OAD|SP|Special|NCOP|NCED|Menu|PV|CM|OP|ED|Preview|Trailer|Bonus|Extra|Omake)[\s\.\-_#]*(0*\d{1,4}(?:\.\d)?)(?!\d)"#, in: epSearchText) {
            if let e = parseEpisodeNumber(m[2]) {
                let rawTag = m[1].uppercased()
                let tag = rawTag == "SPECIAL" ? "SP" : rawTag
                return EpisodeKey(season: explicitSeason, episode: e, specialTag: tag)
            }
        }

        // 4. Explicit episode prefix: Episode 5 / Ep.05 / EP00005 / E05
        for m in allMatches(#"(?i)\b(?:Episode|Ep\.?|E)[\s\.\-_#]*(0*\d{1,4}(?:\.\d)?)(?!\d)"#, in: epSearchText) {
            if let e = parseEpisodeNumber(m[1]) {
                return EpisodeKey(season: explicitSeason, episode: e)
            }
        }

        // 5. Fansub dash pattern: " - 05 " / " - 00001 " / " - 01.5 " / " - 05 ["
        for m in allMatches(#"(?:\s+-\s+|\s+–\s+|\s+—\s+)(0*\d{1,4}(?:\.\d)?)(?![A-Za-z0-9])"#, in: epSearchText) {
            if let e = parseEpisodeNumber(m[1]) {
                return EpisodeKey(season: explicitSeason, episode: e)
            }
        }

        // 6a. Square-bracketed episode number: [05] / [00001] / 【05】
        for m in allMatches(#"[\[\【]\s*(0*\d{1,4}(?:\.\d)?)\s*[\]\】]"#, in: epSearchText) {
            if let e = parseEpisodeNumber(m[1]) {
                return EpisodeKey(season: explicitSeason, episode: e)
            }
        }

        // 6b. Parenthesized episode number: (05) / (00001), avoiding macOS duplicate-copy suffixes like `00002 complete++ (1)`
        let textWithoutParens = replaceRegex(#"[\(\（]\s*0*\d{1,4}(?:\.\d)?\s*[\)\）]"#, in: epSearchText, with: " ")
        let hasUnbracketedZeroPaddedNumber = allMatches(
            #"(?<![A-Za-z0-9])(0+\d{1,4}(?:\.\d)?)(?![A-Za-z0-9])"#,
            in: textWithoutParens
        ).contains { captures in
            captures.count > 1 && parseEpisodeNumber(captures[1]) != nil
        }
        if !hasUnbracketedZeroPaddedNumber {
            for m in allMatches(#"[\(\（]\s*(0*\d{1,4}(?:\.\d)?)\s*[\)\）]"#, in: epSearchText) {
                if let e = parseEpisodeNumber(m[1]) {
                    return EpisodeKey(season: explicitSeason, episode: e)
                }
            }
        }

        // 7. Hash or underscored episode number: #05 / _05_ / _00001_
        for m in allMatches(#"(?:#|_)(0*\d{1,4}(?:\.\d)?)(?![A-Za-z0-9])"#, in: epSearchText) {
            if let e = parseEpisodeNumber(m[1]) {
                return EpisodeKey(season: explicitSeason, episode: e)
            }
        }

        // 8. Trailing standalone episode number or bare number (e.g. "00001", "01", "Show Name 05", "Show.Name.5")
        if let m = firstMatch(#"(?:^|[\s\.\-_])(0*\d{1,4}(?:\.\d)?)\s*$"#, in: epSearchText),
           let e = parseEpisodeNumber(m[1]) {
            return EpisodeKey(season: explicitSeason, episode: e)
        }

        // 9. Standalone-number fallback (e.g. "00001 complete++", "01_final", "0012 (rev2)" after stripping group/meta brackets)
        let standaloneCandidates = allMatches(
            #"(?<![A-Za-z0-9])(0*\d{1,4}(?:\.\d)?)(?![A-Za-z0-9])"#,
            in: textWithoutParens
        ).compactMap { captures -> (raw: String, value: Double, zeroPadded: Bool)? in
            guard captures.count > 1 else { return nil }
            let raw = captures[1]
            guard let value = parseEpisodeNumber(raw) else { return nil }
            let intPart = raw.split(separator: ".").first.map(String.init) ?? raw
            let zeroPadded = intPart.count > 1 && intPart.hasPrefix("0")
            return (raw, value, zeroPadded)
        }
        if let preferred = standaloneCandidates.first(where: \.zeroPadded) ?? standaloneCandidates.first {
            return EpisodeKey(season: explicitSeason, episode: preferred.value)
        }

        return nil
    }

    /// Normalized alphanumeric title tokens (release group brackets & media noise stripped)
    /// used for tie-breaking and Tier 3 conservative special matching.
    public static func normalizedTitleTokens(from filename: String) -> Set<String> {
        var text = sanitizeFilename(filename)
        // Strip explicit season/episode tags so title comparison focuses on title + special words
        text = replaceRegex(#"(?i)\bS\d{1,2}\s*[\.\-_]?\s*E0*\d{1,4}(?:\.\d)?\b"#, in: text, with: " ")
        text = replaceRegex(#"(?i)\bSeason[\s\.\-_]*\d{1,2}\b"#, in: text, with: " ")
        text = replaceRegex(#"(?i)(?:^|[\s\.\-_])S\d{1,2}(?=$|[\s\.\-_])"#, in: text, with: " ")

        let rawTokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) && !titleStopWords.contains($0) }

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
        let rawTokens: Set<String>
        let specialCats: Set<String>

        init(url: URL) {
            self.url = url
            let stem = url.deletingPathExtension().lastPathComponent
            self.stemLower = stem.lowercased()
            let key = EpisodePairing.extractEpisodeKey(from: url.lastPathComponent)
            self.episodeKey = key
            self.season = key?.season ?? EpisodePairing.extractSeason(from: url.lastPathComponent)
            let tokens = EpisodePairing.normalizedTitleTokens(from: url.lastPathComponent)
            self.titleTokens = tokens
            self.rawTokens = Set(
                stem.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            )
            self.specialCats = EpisodePairing.specialCategories(in: tokens)
        }
    }

    private struct MutablePairedRow {
        var source: FileMetadata?
        var target: FileMetadata?
        var subtitle: FileMetadata?
        var episodeKey: EpisodeKey?
        var mediaMatchKind: PairMatchKind
        var subtitleMatchKind: PairMatchKind?

        var season: Int? {
            episodeKey?.season ?? source?.season ?? target?.season ?? subtitle?.season
        }

        var titleTokens: Set<String> {
            var merged: Set<String> = []
            if let src = source { merged.formUnion(src.titleTokens) }
            if let dst = target { merged.formUnion(dst.titleTokens) }
            return merged
        }

        var rawTokens: Set<String> {
            var merged: Set<String> = []
            if let src = source { merged.formUnion(src.rawTokens) }
            if let dst = target { merged.formUnion(dst.rawTokens) }
            return merged
        }

        var specialCats: Set<String> {
            var merged: Set<String> = []
            if let src = source { merged.formUnion(src.specialCats) }
            if let dst = target { merged.formUnion(dst.specialCats) }
            return merged
        }
    }

    public static func pairFiles(
        sources: [URL],
        targets: [URL],
        externalSubtitles: [URL] = [],
        subtitleMode: BatchSubtitleMode = .embedded
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
        var rows: [MutablePairedRow] = []

        // MARK: Media Step — Tier 1: Exact filename or stem ignoring container extension
        var afterTier1: [FileMetadata] = []
        for src in sourceMeta {
            if let dst = targetMeta.first(where: {
                !usedTargets.contains($0.url)
                    && !seasonsConflict(src.season, $0.season)
                    && isExactFilenameMatch(source: src.url, target: $0.url)
            }) {
                usedTargets.insert(dst.url)
                rows.append(
                    MutablePairedRow(
                        source: src,
                        target: dst,
                        subtitle: nil,
                        episodeKey: src.episodeKey ?? dst.episodeKey,
                        mediaMatchKind: .exactFilename,
                        subtitleMatchKind: nil
                    )
                )
            } else {
                afterTier1.append(src)
            }
        }

        // MARK: Media Step — Tier 2a: Explicit matching season + normalized episode number
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
            if let best = bestByTitleSimilarity(for: src.titleTokens, among: candidates) {
                usedTargets.insert(best.url)
                rows.append(
                    MutablePairedRow(
                        source: src,
                        target: best,
                        subtitle: nil,
                        episodeKey: srcKey,
                        mediaMatchKind: .episodeRegex,
                        subtitleMatchKind: nil
                    )
                )
            } else {
                afterTier2a.append(src)
            }
        }

        // MARK: Media Step — Tier 2b: Normalized episode number with non-conflicting season
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
            if let best = bestByTitleSimilarity(for: src.titleTokens, among: candidates) {
                usedTargets.insert(best.url)
                let mergedKey = EpisodeKey(
                    season: src.season ?? best.season,
                    episode: srcKey.episode,
                    specialTag: srcKey.specialTag
                )
                rows.append(
                    MutablePairedRow(
                        source: src,
                        target: best,
                        subtitle: nil,
                        episodeKey: mergedKey,
                        mediaMatchKind: .episodeRegex,
                        subtitleMatchKind: nil
                    )
                )
            } else {
                afterTier2b.append(src)
            }
        }

        // MARK: Media Step — Tier 3: Conservative title similarity fallback for non-numbered specials
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
                if !src.specialCats.isEmpty && !dst.specialCats.isEmpty && src.specialCats.isDisjoint(with: dst.specialCats) {
                    return false
                }
                return titleSimilarity(src.titleTokens, dst.titleTokens) >= 0.60
            }

            if let best = bestByTitleSimilarity(for: src.titleTokens, among: candidates) {
                usedTargets.insert(best.url)
                rows.append(
                    MutablePairedRow(
                        source: src,
                        target: best,
                        subtitle: nil,
                        episodeKey: nil,
                        mediaMatchKind: .titleSimilarity,
                        subtitleMatchKind: nil
                    )
                )
            } else {
                unmatchedSources.append(src)
            }
        }

        // Unmatched single-sided media rows ("No match found" on missing side)
        for src in unmatchedSources {
            rows.append(
                MutablePairedRow(
                    source: src,
                    target: nil,
                    subtitle: nil,
                    episodeKey: src.episodeKey,
                    mediaMatchKind: .unmatched,
                    subtitleMatchKind: nil
                )
            )
        }

        for dst in targetMeta where !usedTargets.contains(dst.url) {
            rows.append(
                MutablePairedRow(
                    source: nil,
                    target: dst,
                    subtitle: nil,
                    episodeKey: dst.episodeKey,
                    mediaMatchKind: .unmatched,
                    subtitleMatchKind: nil
                )
            )
        }

        // MARK: Unified Multi-Tier External Subtitle Pairing
        // Runs the exact same strict-season-safe Tier 1 -> Tier 2a -> Tier 2b -> Tier 3 cascade
        // across all rows (including partial 1-sided Source-only or Target-only rows).
        if !subMeta.isEmpty {
            var usedSubs: Set<URL> = []

            // Subtitle Tier 1: Exact filename or exact stem ignoring extension
            for idx in rows.indices where rows[idx].subtitle == nil {
                let row = rows[idx]
                let exactCandidate = subMeta.first { sub in
                    guard !usedSubs.contains(sub.url),
                          !seasonsConflict(row.season, sub.season) else { return false }
                    if let src = row.source, isExactFilenameMatch(source: src.url, target: sub.url) {
                        return true
                    }
                    if let dst = row.target, isExactFilenameMatch(source: dst.url, target: sub.url) {
                        return true
                    }
                    return false
                }
                if let sub = exactCandidate {
                    usedSubs.insert(sub.url)
                    rows[idx].subtitle = sub
                    rows[idx].subtitleMatchKind = .exactFilename
                    if rows[idx].episodeKey == nil {
                        rows[idx].episodeKey = sub.episodeKey
                    }
                }
            }

            // Subtitle Tier 2a: Explicit matching season + normalized episode number
            for idx in rows.indices where rows[idx].subtitle == nil {
                let row = rows[idx]
                guard let rowKey = row.episodeKey, let rowSeason = row.season else { continue }
                let candidates = subMeta.filter { sub in
                    guard !usedSubs.contains(sub.url),
                          let subKey = sub.episodeKey,
                          let subSeason = sub.season else { return false }
                    return rowSeason == subSeason
                        && rowKey.episode == subKey.episode
                        && rowKey.specialTag == subKey.specialTag
                }
                if let best = bestByTitleSimilarity(for: row.titleTokens, rawReferenceTokens: row.rawTokens, among: candidates) {
                    usedSubs.insert(best.url)
                    rows[idx].subtitle = best
                    rows[idx].subtitleMatchKind = .episodeRegex
                }
            }

            // Subtitle Tier 2b: Normalized episode number with non-conflicting season
            for idx in rows.indices where rows[idx].subtitle == nil {
                let row = rows[idx]
                guard let rowKey = row.episodeKey else { continue }
                let candidates = subMeta.filter { sub in
                    guard !usedSubs.contains(sub.url),
                          let subKey = sub.episodeKey else { return false }
                    guard !seasonsConflict(row.season, sub.season) else { return false }
                    return rowKey.episode == subKey.episode
                        && rowKey.specialTag == subKey.specialTag
                }
                if let best = bestByTitleSimilarity(for: row.titleTokens, rawReferenceTokens: row.rawTokens, among: candidates) {
                    usedSubs.insert(best.url)
                    rows[idx].subtitle = best
                    rows[idx].subtitleMatchKind = .episodeRegex
                    if rowKey.season == nil, let subSeason = best.season {
                        rows[idx].episodeKey = EpisodeKey(
                            season: subSeason,
                            episode: rowKey.episode,
                            specialTag: rowKey.specialTag
                        )
                    }
                }
            }

            // Subtitle Tier 3: Conservative normalized-title similarity fallback for non-numbered specials
            for idx in rows.indices where rows[idx].subtitle == nil {
                let row = rows[idx]
                guard row.episodeKey == nil else { continue }
                let rowTokens = row.titleTokens
                let rowCats = row.specialCats
                let candidates = subMeta.filter { sub in
                    guard !usedSubs.contains(sub.url),
                          sub.episodeKey == nil,
                          !seasonsConflict(row.season, sub.season) else { return false }
                    if !rowCats.isEmpty && !sub.specialCats.isEmpty && rowCats.isDisjoint(with: sub.specialCats) {
                        return false
                    }
                    return titleSimilarity(rowTokens, sub.titleTokens) >= 0.60
                }
                if let best = bestByTitleSimilarity(for: rowTokens, rawReferenceTokens: row.rawTokens, among: candidates) {
                    usedSubs.insert(best.url)
                    rows[idx].subtitle = best
                    rows[idx].subtitleMatchKind = .titleSimilarity
                }
            }

            // Unmatched external subtitles become explicit rows with "No match found" on missing media sides
            for sub in subMeta where !usedSubs.contains(sub.url) {
                rows.append(
                    MutablePairedRow(
                        source: nil,
                        target: nil,
                        subtitle: sub,
                        episodeKey: sub.episodeKey,
                        mediaMatchKind: .unmatched,
                        subtitleMatchKind: .unmatched
                    )
                )
            }
        }

        // MARK: Build Final Drafts & Verification Status
        let drafts: [PairedEpisodeDraft] = rows.map { row in
            let finalMatchKind: PairMatchKind
            let isVerified: Bool

            switch subtitleMode {
            case .embedded:
                if row.source != nil && row.target != nil {
                    finalMatchKind = row.mediaMatchKind
                    isVerified = (row.mediaMatchKind == .exactFilename)
                } else {
                    finalMatchKind = .unmatched
                    isVerified = false
                }
            case .external:
                if row.source != nil && row.target != nil && row.subtitle != nil {
                    let combined = PairMatchKind.combined(row.mediaMatchKind, row.subtitleMatchKind ?? .unmatched)
                    finalMatchKind = combined
                    isVerified = (combined == .exactFilename)
                } else {
                    finalMatchKind = .unmatched
                    isVerified = false
                }
            }

            return PairedEpisodeDraft(
                episodeKey: row.episodeKey,
                sourceFile: row.source?.url,
                targetFile: row.target?.url,
                externalSubtitleFile: row.subtitle?.url,
                matchKind: finalMatchKind,
                subtitleMatchKind: row.subtitleMatchKind,
                isVerified: isVerified
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
            let lName = lhs.sourceFile?.lastPathComponent
                ?? lhs.targetFile?.lastPathComponent
                ?? lhs.externalSubtitleFile?.lastPathComponent
                ?? ""
            let rName = rhs.sourceFile?.lastPathComponent
                ?? rhs.targetFile?.lastPathComponent
                ?? rhs.externalSubtitleFile?.lastPathComponent
                ?? ""
            return lName.localizedStandardCompare(rName) == .orderedAscending
        }
    }

    private static func bestByTitleSimilarity(
        for referenceTokens: Set<String>,
        rawReferenceTokens: Set<String> = [],
        among candidates: [FileMetadata]
    ) -> FileMetadata? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        return candidates.max { lhs, rhs in
            let s1 = titleSimilarity(referenceTokens, lhs.titleTokens)
            let s2 = titleSimilarity(referenceTokens, rhs.titleTokens)
            if s1 != s2 { return s1 < s2 }
            if !rawReferenceTokens.isEmpty {
                let r1 = titleSimilarity(rawReferenceTokens, lhs.rawTokens)
                let r2 = titleSimilarity(rawReferenceTokens, rhs.rawTokens)
                if r1 != r2 { return r1 < r2 }
            }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedDescending
        }
    }

    /// Recursively scans `directory` (including nested subfolders and symlinked directories)
    /// for supported media and subtitle files while skipping hidden files, generated `.sushi.`
    /// outputs, and any nested `Merged Files` output subfolder.
    public static func scanMediaFiles(in directory: URL) -> (media: [URL], subtitles: [URL]) {
        let fm = FileManager.default
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var media: [URL] = []
        var subs: [URL] = []
        var visitedDirs: Set<String> = []

        func walk(_ currentDir: URL) {
            let canonicalPath = currentDir.resolvingSymlinksInPath().path
            guard visitedDirs.insert(canonicalPath).inserted else { return }

            guard let entries = try? fm.contentsOfDirectory(
                at: currentDir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            let sortedEntries = entries.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            for entry in sortedEntries {
                let name = entry.lastPathComponent
                if name.hasPrefix(".") { continue }

                let resolved = entry.resolvingSymlinksInPath()
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir) else { continue }

                if isDir.boolValue {
                    if name == "Merged Files" {
                        continue
                    }
                    walk(resolved)
                } else {
                    let ext = entry.pathExtension.lowercased()
                    let normalizedURL = entry.standardizedFileURL
                    if mediaExtensions.contains(ext) {
                        media.append(normalizedURL)
                    } else if subtitleExtensions.contains(ext),
                              !name.localizedCaseInsensitiveContains(".sushi.") {
                        subs.append(normalizedURL)
                    }
                }
            }
        }

        walk(root)
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

    private static func allMatches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { idx in
                let r = match.range(at: idx)
                guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return "" }
                return String(text[swiftRange])
            }
        }
    }

    private static func replaceRegex(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
