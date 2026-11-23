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
    /// Exact filename or exact filename stem ignoring container extension (auto-verified).
    case exactFilename
    /// Matched via episode number regex with differing filenames (starts unverified).
    case episodeRegex
    /// Positional fallback or incomplete pair (starts unverified).
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

    /// Convenience alias preserved for clarity: true for exact-name or regex episode matches.
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

/// Extracts episode identifiers from anime/TV release filenames while filtering out
/// resolution, codec, bit-depth, CRC32 hashes, and release years.
public enum EpisodePairing {
    public static let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "webm", "m4v", "mov"]
    public static let audioExtensions: Set<String> = ["flac", "wav", "aac", "ac3", "eac3", "m4a", "mp3", "opus", "pcm", "mka"]
    public static let subtitleExtensions: Set<String> = ["ass", "ssa", "srt"]
    public static let mediaExtensions: Set<String> = videoExtensions.union(audioExtensions)

    private static let noisePatterns: [String] = [
        #"\[[0-9A-Fa-f]{8}\]"#,                                      // CRC32 tags like [A1B2C3D4]
        #"\b(2160|1080|720|576|480)[pi]\b"#,                         // Video resolution
        #"\b(x|h)\.?26[45]\b"#,                                      // Video codec x264/H.265
        #"\b(10|8)[\s\-]?bit\b"#,                                    // Bit depth
        #"\b(aac|ac3|eac3|ddp|dts|flac)[\s\.]?\d(\.\d)?\b"#,         // Audio codec + channels
        #"\b[257]\.[01]\b"#,                                         // Channel layout 5.1 / 2.0
        #"\bv[0-4]\b"#,                                              // Release version v2
        #"[\(\[](19|20)\d{2}[\)\]]"#,                                 // Release year (2024)
    ]

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
        for pattern in noisePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: " ")
            }
        }
        return cleaned
    }

    public static func extractEpisodeKey(from filename: String) -> EpisodeKey? {
        let cleaned = sanitizeFilename(filename)

        // 1. S01E02 / S1E02.5 / S01E02v2
        if let m = firstMatch(#"(?i)\bS(\d{1,2})\s*[\.\-_]?\s*E(\d{1,3}(?:\.\d)?)\b"#, in: cleaned),
           let s = Int(m[1]), let e = Double(m[2]) {
            return EpisodeKey(season: s, episode: e)
        }

        // 2. 1x02
        if let m = firstMatch(#"(?i)\b(\d{1,2})x(\d{1,3}(?:\.\d)?)\b"#, in: cleaned),
           let s = Int(m[1]), let e = Double(m[2]) {
            return EpisodeKey(season: s, episode: e)
        }

        // 3. Specials / OVA / OAD / SP / NCOP / NCED
        if let m = firstMatch(#"(?i)\b(OVA|OAD|SP|NCOP|NCED)[\s\.\-_#]*(\d{1,2}(?:\.\d)?)\b"#, in: cleaned),
           let e = Double(m[2]) {
            return EpisodeKey(season: nil, episode: e, specialTag: m[1].uppercased())
        }

        // 4. Episode 02 / Ep.02 / EP 02 / E02
        if let m = firstMatch(#"(?i)\b(?:Episode|Ep\.?|E)[\s\.\-_#]*(\d{1,3}(?:\.\d)?)\b"#, in: cleaned),
           let e = Double(m[1]) {
            return EpisodeKey(season: nil, episode: e)
        }

        // 5. Anime fansub dash pattern: " - 01 " or " - 01v2 " or " - 01 (" or end of string
        if let m = firstMatch(#"(?:\s+-\s+|\s+–\s+)(\d{1,3}(?:\.\d)?)(?=\s|$|[\[\(\-_])"#, in: cleaned),
           let e = Double(m[1]) {
            return EpisodeKey(season: nil, episode: e)
        }

        // 6. Bracketed episode number: [01] or (01)
        if let m = firstMatch(#"[\[\(](\d{1,3}(?:\.\d)?)[\]\)]"#, in: cleaned),
           let e = Double(m[1]) {
            return EpisodeKey(season: nil, episode: e)
        }

        // 7. Standalone hash or underscored number: #01 or _01_
        if let m = firstMatch(#"(?:#|_)(\d{1,3}(?:\.\d)?)(?=\b|_|\s|$)"#, in: cleaned),
           let e = Double(m[1]) {
            return EpisodeKey(season: nil, episode: e)
        }

        // 8. Trailing standalone number at end of title (e.g. "Show Name 01")
        if let m = firstMatch(#"\b(\d{1,3})\s*$"#, in: cleaned),
           let e = Double(m[1]), e < 1900 {
            return EpisodeKey(season: nil, episode: e)
        }

        return nil
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

        var targetsByStem: [String: [URL]] = [:]
        var targetsByKey: [EpisodeKey: [URL]] = [:]
        var targetsByEpOnly: [Double: [URL]] = [:]

        for url in sortedTargets {
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            targetsByStem[stem, default: []].append(url)
            if let key = extractEpisodeKey(from: url.lastPathComponent) {
                targetsByKey[key, default: []].append(url)
                if key.specialTag == nil {
                    targetsByEpOnly[key.episode, default: []].append(url)
                }
            }
        }

        var subsByKey: [EpisodeKey: [URL]] = [:]
        var subsByEpOnly: [Double: [URL]] = [:]
        var subsByStem: [String: URL] = [:]
        for sub in sortedSubs {
            let stem = sub.deletingPathExtension().lastPathComponent.lowercased()
            subsByStem[stem] = sub
            if let key = extractEpisodeKey(from: sub.lastPathComponent) {
                subsByKey[key, default: []].append(sub)
                if key.specialTag == nil {
                    subsByEpOnly[key.episode, default: []].append(sub)
                }
            }
        }

        var usedTargets: Set<URL> = []
        var usedSubs: Set<URL> = []
        var drafts: [PairedEpisodeDraft] = []
        var remainingSourcesAfterExact: [URL] = []

        func claimSub(for src: URL, key: EpisodeKey?) -> URL? {
            let stem = src.deletingPathExtension().lastPathComponent.lowercased()
            if let exact = subsByStem[stem], !usedSubs.contains(exact) {
                usedSubs.insert(exact)
                return exact
            }
            if let key {
                if let list = subsByKey[key], let candidate = list.first(where: { !usedSubs.contains($0) }) {
                    usedSubs.insert(candidate)
                    return candidate
                }
                if key.specialTag == nil,
                   let list = subsByEpOnly[key.episode],
                   let candidate = list.first(where: { !usedSubs.contains($0) }) {
                    usedSubs.insert(candidate)
                    return candidate
                }
            }
            return nil
        }

        // Pass 1: Exact filename or exact stem matches -> automatically Verified.
        for src in sortedSources {
            let stem = src.deletingPathExtension().lastPathComponent.lowercased()
            if let candidates = targetsByStem[stem],
               let dst = candidates.first(where: { !usedTargets.contains($0) && isExactFilenameMatch(source: src, target: $0) }) {
                usedTargets.insert(dst)
                let key = extractEpisodeKey(from: src.lastPathComponent)
                drafts.append(
                    PairedEpisodeDraft(
                        episodeKey: key,
                        sourceFile: src,
                        targetFile: dst,
                        externalSubtitleFile: claimSub(for: src, key: key),
                        matchKind: .exactFilename,
                        isVerified: true
                    )
                )
            } else {
                remainingSourcesAfterExact.append(src)
            }
        }

        // Pass 2: Episode-number regex matches with differing filenames -> Unverified until confirmed.
        var unmatchedSources: [URL] = []
        for src in remainingSourcesAfterExact {
            guard let srcKey = extractEpisodeKey(from: src.lastPathComponent) else {
                unmatchedSources.append(src)
                continue
            }

            if let candidates = targetsByKey[srcKey],
               let dst = candidates.first(where: { !usedTargets.contains($0) }) {
                usedTargets.insert(dst)
                let exact = isExactFilenameMatch(source: src, target: dst)
                drafts.append(
                    PairedEpisodeDraft(
                        episodeKey: srcKey,
                        sourceFile: src,
                        targetFile: dst,
                        externalSubtitleFile: claimSub(for: src, key: srcKey),
                        matchKind: exact ? .exactFilename : .episodeRegex,
                        isVerified: exact
                    )
                )
                continue
            }

            if srcKey.specialTag == nil,
               let candidates = targetsByEpOnly[srcKey.episode],
               let dst = candidates.first(where: { !usedTargets.contains($0) }) {
                usedTargets.insert(dst)
                let exact = isExactFilenameMatch(source: src, target: dst)
                drafts.append(
                    PairedEpisodeDraft(
                        episodeKey: srcKey,
                        sourceFile: src,
                        targetFile: dst,
                        externalSubtitleFile: claimSub(for: src, key: srcKey),
                        matchKind: exact ? .exactFilename : .episodeRegex,
                        isVerified: exact
                    )
                )
                continue
            }

            unmatchedSources.append(src)
        }

        // Pass 3: Remaining unmatched sources and targets -> positional fallback, Unverified.
        let unmatchedTargets = sortedTargets.filter { !usedTargets.contains($0) }
        let leftoverCount = max(unmatchedSources.count, unmatchedTargets.count)
        for i in 0..<leftoverCount {
            let s = i < unmatchedSources.count ? unmatchedSources[i] : nil
            let t = i < unmatchedTargets.count ? unmatchedTargets[i] : nil
            let sub = s.flatMap { claimSub(for: $0, key: extractEpisodeKey(from: $0.lastPathComponent)) }
            let key = s.flatMap { extractEpisodeKey(from: $0.lastPathComponent) }
                ?? t.flatMap { extractEpisodeKey(from: $0.lastPathComponent) }
            drafts.append(
                PairedEpisodeDraft(
                    episodeKey: key,
                    sourceFile: s,
                    targetFile: t,
                    externalSubtitleFile: sub,
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
}
