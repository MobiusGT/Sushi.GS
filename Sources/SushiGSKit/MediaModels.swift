import Foundation

public struct VideoTrack: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var codec: String
    public var width: Int
    public var height: Int
    public var `default`: Bool
    public var title: String

    public init(id: Int, codec: String, width: Int, height: Int, default: Bool = false, title: String = "") {
        self.id = id
        self.codec = codec
        self.width = width
        self.height = height
        self.default = `default`
        self.title = title
    }

    public var resolutionLabel: String {
        width > 0 && height > 0 ? "\(width)×\(height)" : "Unknown"
    }
}

public struct AudioTrack: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var codec: String
    public var lang: String
    public var title: String
    public var channelLayout: String
    public var channels: Int
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var `default`: Bool
    public var forced: Bool

    public init(
        id: Int,
        codec: String,
        lang: String = "und",
        title: String = "",
        channelLayout: String = "",
        channels: Int = 2,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        default: Bool = false,
        forced: Bool = false
    ) {
        self.id = id
        self.codec = codec
        self.lang = lang
        self.title = title
        self.channelLayout = channelLayout
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.default = `default`
        self.forced = forced
    }

    public var isLossless: Bool {
        let lower = codec.lowercased()
        return lower == "flac" || lower == "wav" || lower.hasPrefix("pcm") || lower == "truehd" || lower == "alac"
    }

    public var displayLabel: String {
        var parts: [String] = ["Track \(id)"]
        if !title.isEmpty {
            parts.append(title)
        }
        parts.append(lang.uppercased())
        if !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if !channelLayout.isEmpty {
            parts.append(channelLayout)
        } else if channels > 0 {
            parts.append("\(channels)ch")
        }
        if let sr = sampleRate, sr > 0 {
            parts.append("\(sr / 1000) kHz")
        }
        var flags: [String] = []
        if `default` { flags.append("Default") }
        if forced { flags.append("Forced") }
        let base = parts.joined(separator: " · ")
        return flags.isEmpty ? base : "\(base) [\(flags.joined(separator: ", "))]"
    }
}

public struct SubtitleTrack: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var codec: String
    public var lang: String
    public var title: String
    public var extensionName: String
    public var supported: Bool
    public var `default`: Bool
    public var forced: Bool

    enum CodingKeys: String, CodingKey {
        case id, codec, lang, title, supported, `default`, forced
        case extensionName = "extension"
    }

    public init(
        id: Int,
        codec: String,
        lang: String = "und",
        title: String = "",
        extensionName: String = ".ass",
        supported: Bool = true,
        default: Bool = false,
        forced: Bool = false
    ) {
        self.id = id
        self.codec = codec
        self.lang = lang
        self.title = title
        self.extensionName = extensionName
        self.supported = supported
        self.default = `default`
        self.forced = forced
    }

    public var displayLabel: String {
        var parts: [String] = ["Track \(id)"]
        if !title.isEmpty {
            parts.append(title)
        }
        parts.append(lang.uppercased())
        if !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        var flags: [String] = []
        if `default` { flags.append("Default") }
        if forced { flags.append("Forced") }
        if !supported { flags.append("Unsupported") }
        let base = parts.joined(separator: " · ")
        return flags.isEmpty ? base : "\(base) [\(flags.joined(separator: ", "))]"
    }
}

public struct MediaProbeResult: Codable, Hashable, Sendable {
    public var filepath: String
    public var filename: String
    public var formatName: String
    public var durationSeconds: Double?
    public var chapterCount: Int
    public var videoTracks: [VideoTrack]
    public var audioTracks: [AudioTrack]
    public var subtitleTracks: [SubtitleTrack]

    public init(
        filepath: String,
        filename: String,
        formatName: String = "",
        durationSeconds: Double? = nil,
        chapterCount: Int = 0,
        videoTracks: [VideoTrack] = [],
        audioTracks: [AudioTrack] = [],
        subtitleTracks: [SubtitleTrack] = []
    ) {
        self.filepath = filepath
        self.filename = filename
        self.formatName = formatName
        self.durationSeconds = durationSeconds
        self.chapterCount = chapterCount
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
    }

    public var supportedSubtitleTracks: [SubtitleTrack] {
        subtitleTracks.filter(\.supported)
    }

    public var formattedDuration: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let total = Int(durationSeconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

public enum JobStatus: String, Codable, Hashable, Sendable {
    case pending
    case running
    case succeeded
    case warned
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .pending: "Ready"
        case .running: "Running"
        case .succeeded: "Synced"
        case .warned: "Warning"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    public var symbolName: String {
        switch self {
        case .pending: "circle"
        case .running: "arrow.trianglehead.2.clockwise"
        case .succeeded: "checkmark.circle.fill"
        case .warned: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "slash.circle"
        }
    }
}

public enum LogSeverity: String, Codable, Hashable, CaseIterable, Sendable {
    case info
    case warning
    case error

    public var displayName: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

public struct LogEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var lineIndex: Int
    public var timestamp: String
    public var source: String
    public var severity: LogSeverity
    public var line: String
    public var jobID: UUID?

    public init(
        id: UUID = UUID(),
        lineIndex: Int,
        timestamp: String,
        source: String,
        severity: LogSeverity,
        line: String,
        jobID: UUID? = nil
    ) {
        self.id = id
        self.lineIndex = lineIndex
        self.timestamp = timestamp
        self.source = source
        self.severity = severity
        self.line = line
        self.jobID = jobID
    }
}

public struct SyncWarning: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var code: String
    public var summary: String
    public var lineIndex: Int

    public init(id: UUID = UUID(), code: String, summary: String, lineIndex: Int) {
        self.id = id
        self.code = code
        self.summary = summary
        self.lineIndex = lineIndex
    }
}

public struct SyncMetrics: Codable, Hashable, Sendable {
    public var avgShiftSeconds: Double?
    public var medianDiff: Double?
    public var maxDiff: Double?
    public var maxShiftJumpSeconds: Double?
    public var eventCount: Int
    public var groupCount: Int
    public var brokenSegments: Int
    public var maxWindowHits: Int
    public var outOfRangeEvents: Int
    public var borderFixes: Int
    public var warningCount: Int

    public init(
        avgShiftSeconds: Double? = nil,
        medianDiff: Double? = nil,
        maxDiff: Double? = nil,
        maxShiftJumpSeconds: Double? = nil,
        eventCount: Int = 0,
        groupCount: Int = 0,
        brokenSegments: Int = 0,
        maxWindowHits: Int = 0,
        outOfRangeEvents: Int = 0,
        borderFixes: Int = 0,
        warningCount: Int = 0
    ) {
        self.avgShiftSeconds = avgShiftSeconds
        self.medianDiff = medianDiff
        self.maxDiff = maxDiff
        self.maxShiftJumpSeconds = maxShiftJumpSeconds
        self.eventCount = eventCount
        self.groupCount = groupCount
        self.brokenSegments = brokenSegments
        self.maxWindowHits = maxWindowHits
        self.outOfRangeEvents = outOfRangeEvents
        self.borderFixes = borderFixes
        self.warningCount = warningCount
    }

    public var formattedAverageShift: String? {
        guard let avg = avgShiftSeconds else { return nil }
        return String(format: "%+.3fs", avg)
    }
}

/// Batch-wide rule for selecting audio or subtitle tracks across multiple episodes,
/// with optional per-episode overrides.
public struct BatchTrackRule: Codable, Hashable, Sendable {
    public enum MatchMode: String, Codable, CaseIterable, Sendable {
        case firstOrDefault
        case trackPosition
        case streamID
        case languageAndTitle

        public var displayName: String {
            switch self {
            case .firstOrDefault: "Default / First Track"
            case .trackPosition: "By Track Position (1st, 2nd…)"
            case .streamID: "By Exact Stream ID"
            case .languageAndTitle: "By Language / Title Filter"
            }
        }
    }

    public var mode: MatchMode
    public var trackPosition: Int // 1-based ordinal among tracks of the same kind
    public var streamID: Int
    public var languageFilter: String
    public var titleContains: String

    public init(
        mode: MatchMode = .firstOrDefault,
        trackPosition: Int = 1,
        streamID: Int = 1,
        languageFilter: String = "",
        titleContains: String = ""
    ) {
        self.mode = mode
        self.trackPosition = trackPosition
        self.streamID = streamID
        self.languageFilter = languageFilter
        self.titleContains = titleContains
    }

    public func resolveAudio(in tracks: [AudioTrack]) -> AudioTrack? {
        guard !tracks.isEmpty else { return nil }
        switch mode {
        case .firstOrDefault:
            return tracks.first(where: \.default) ?? tracks.first
        case .trackPosition:
            let idx = max(0, trackPosition - 1)
            return tracks.indices.contains(idx) ? tracks[idx] : tracks.first
        case .streamID:
            return tracks.first(where: { $0.id == streamID }) ?? tracks.first
        case .languageAndTitle:
            let langQuery = languageFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let titleQuery = titleContains.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matched = tracks.first { track in
                let langOK = langQuery.isEmpty || track.lang.lowercased().contains(langQuery)
                let titleOK = titleQuery.isEmpty || track.title.lowercased().contains(titleQuery)
                return langOK && titleOK
            }
            return matched ?? tracks.first(where: \.default) ?? tracks.first
        }
    }

    public func resolveSubtitles(in tracks: [SubtitleTrack]) -> [SubtitleTrack] {
        let supported = tracks.filter(\.supported)
        guard !supported.isEmpty else { return [] }
        switch mode {
        case .firstOrDefault:
            return [supported.first(where: \.default) ?? supported[0]]
        case .trackPosition:
            let idx = max(0, trackPosition - 1)
            return [supported.indices.contains(idx) ? supported[idx] : supported[0]]
        case .streamID:
            if let hit = supported.first(where: { $0.id == streamID }) {
                return [hit]
            }
            return [supported[0]]
        case .languageAndTitle:
            let langQuery = languageFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let titleQuery = titleContains.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hits = supported.filter { track in
                let langOK = langQuery.isEmpty || track.lang.lowercased().contains(langQuery)
                let titleOK = titleQuery.isEmpty || track.title.lowercased().contains(titleQuery)
                return langOK && titleOK
            }
            return hits.isEmpty ? [supported.first(where: \.default) ?? supported[0]] : hits
        }
    }
}
