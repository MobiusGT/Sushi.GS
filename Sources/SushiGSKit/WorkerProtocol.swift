import Foundation

/// Subtitle target passed to `worker.py run-job` (either an embedded track or an external file).
public struct WorkerSubtitleTarget: Codable, Hashable, Sendable {
    public var kind: String // "embedded" or "external"
    public var streamId: Int?
    public var filepath: String?
    public var lang: String
    public var title: String
    public var extensionName: String
    public var `default`: Bool
    public var forced: Bool

    enum CodingKeys: String, CodingKey {
        case kind, streamId, filepath, lang, title, `default`, forced
        case extensionName = "extension"
    }

    public static func embedded(_ track: SubtitleTrack) -> WorkerSubtitleTarget {
        WorkerSubtitleTarget(
            kind: "embedded",
            streamId: track.id,
            filepath: nil,
            lang: track.lang,
            title: track.title,
            extensionName: track.extensionName,
            default: track.default,
            forced: track.forced
        )
    }

    public static func external(url: URL, lang: String = "und", title: String = "") -> WorkerSubtitleTarget {
        let ext = "." + url.pathExtension.lowercased()
        return WorkerSubtitleTarget(
            kind: "external",
            streamId: nil,
            filepath: url.path,
            lang: lang,
            title: title,
            extensionName: ext,
            default: true,
            forced: false
        )
    }
}

public struct WorkerExistingSyncedOutput: Codable, Hashable, Sendable {
    public var syncedPath: String
    public var lang: String
    public var title: String
    public var `default`: Bool
    public var forced: Bool

    public init(syncedPath: String, lang: String = "und", title: String = "", default: Bool = true, forced: Bool = false) {
        self.syncedPath = syncedPath
        self.lang = lang
        self.title = title
        self.default = `default`
        self.forced = forced
    }
}

/// JSON payload written to `worker.py run-job` stdin.
public struct WorkerJobPayload: Codable, Sendable {
    public struct SettingsPayload: Codable, Sendable {
        public struct AudioEncodePayload: Codable, Sendable {
            public var enabled: Bool
            public var tracksScope: String
            public var codec: String
            public var profiles: [String: AudioCodecProfile]
        }

        public var general: GeneralSettings
        public var sync: SyncSettings
        public var merge: MergeSettings
        public var audioEncode: AudioEncodePayload

        public init(config: AppConfiguration) {
            self.general = config.general
            self.sync = config.sync
            self.merge = config.merge
            self.audioEncode = AudioEncodePayload(
                enabled: config.audioEncode.enabled,
                tracksScope: config.audioEncode.tracksScope.rawValue,
                codec: config.audioEncode.codec.rawValue,
                profiles: [
                    "opus": AudioCodecProfile(encoder: config.audioEncode.opusEncoder.rawValue, bitrates: config.audioEncode.opusBitrates),
                    "aac": AudioCodecProfile(encoder: "aac", bitrates: config.audioEncode.aacBitrates),
                    "eac3": AudioCodecProfile(encoder: "eac3", bitrates: config.audioEncode.eac3Bitrates),
                ]
            )
        }
    }

    public var mode: String // "sync" or "merge"
    public var jobIndex: Int
    public var srcFilepath: String
    public var dstFilepath: String
    public var srcAudioStreamId: Int?
    public var dstAudioStreamId: Int?
    public var subtitleTargets: [WorkerSubtitleTarget]
    public var existingSyncedOutputs: [WorkerExistingSyncedOutput]
    public var outputDir: String?
    public var binDirs: [String]
    public var toolOverrides: [String: String]
    public var runtimeDataDir: String
    public var logsDir: String
    public var settings: SettingsPayload

    public init(
        mode: String = "sync",
        jobIndex: Int = 1,
        srcFilepath: String,
        dstFilepath: String,
        srcAudioStreamId: Int?,
        dstAudioStreamId: Int?,
        subtitleTargets: [WorkerSubtitleTarget],
        existingSyncedOutputs: [WorkerExistingSyncedOutput] = [],
        outputDir: String?,
        paths: AppPaths,
        config: AppConfiguration
    ) {
        let resolver = BinaryResolver(paths: paths, overrides: config.binaryOverrides)
        self.mode = mode
        self.jobIndex = jobIndex
        self.srcFilepath = srcFilepath
        self.dstFilepath = dstFilepath
        self.srcAudioStreamId = srcAudioStreamId
        self.dstAudioStreamId = dstAudioStreamId
        self.subtitleTargets = subtitleTargets
        self.existingSyncedOutputs = existingSyncedOutputs
        self.outputDir = outputDir
        self.binDirs = resolver.resolvedBinDirectories()
        self.toolOverrides = config.binaryOverrides
        self.runtimeDataDir = paths.runtimeDataDir.path
        self.logsDir = paths.logsDir.path
        self.settings = SettingsPayload(config: config)
    }
}

public struct WorkerSelfCheckResult: Codable, Hashable, Sendable {
    public var ok: Bool
    public var versions: [String: String]
    public var tools: [String: String?]
    public var headlessVerified: Bool
}

public struct WorkerJobResult: Codable, Hashable, Sendable {
    public var ok: Bool
    public var syncedFiles: [String]
    public var mergedFilepath: String?
    public var mergeSucceeded: Bool
    public var hasWarnings: Bool
    public var warnings: [WorkerWarningDTO]
    public var metrics: SyncMetrics?
    public var sushiLogPath: String?
    public var mergeLogPath: String?
}

public struct WorkerWarningDTO: Codable, Hashable, Sendable {
    public var code: String
    public var summary: String
    public var lineIndex: Int
}

/// Decoded NDJSON event emitted by `worker.py` on stdout.
public enum WorkerEvent: Sendable {
    case stage(name: String, detail: String, timestamp: String)
    case progress(fraction: Double, stage: String, timestamp: String)
    case log(source: String, severity: LogSeverity, line: String, lineIndex: Int, timestamp: String)
    case warning(code: String, summary: String, lineIndex: Int, timestamp: String)
    case metrics(SyncMetrics, timestamp: String)
    case selfCheckResult(WorkerSelfCheckResult)
    case probeResult(MediaProbeResult)
    case jobResult(WorkerJobResult)
    case error(code: String, message: String, timestamp: String)
}

public enum WorkerEventParser {
    private struct Envelope: Decodable {
        var type: String
        var timestamp: String?
        // stage / progress
        var stage: String?
        var detail: String?
        var fraction: Double?
        // log
        var source: String?
        var level: String?
        var line: String?
        var lineIndex: Int?
        // warning
        var code: String?
        var summary: String?
        // error
        var message: String?
        // metrics
        var metrics: SyncMetrics?
        // results
        var ok: Bool?
        var versions: [String: String]?
        var tools: [String: String?]?
        var headlessVerified: Bool?
        var probe: MediaProbeResult?
        var syncedFiles: [String]?
        var mergedFilepath: String?
        var mergeSucceeded: Bool?
        var hasWarnings: Bool?
        var warnings: [WorkerWarningDTO]?
        var sushiLogPath: String?
        var mergeLogPath: String?
    }

    public static func parse(line: String) -> WorkerEvent? {
        guard let data = line.data(using: .utf8),
              let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }
        let ts = env.timestamp ?? ""
        switch env.type {
        case "stage":
            return .stage(name: env.stage ?? "", detail: env.detail ?? "", timestamp: ts)
        case "progress":
            return .progress(fraction: min(max(env.fraction ?? 0, 0), 1), stage: env.stage ?? "", timestamp: ts)
        case "log":
            let sev = LogSeverity(rawValue: env.level ?? "info") ?? .info
            return .log(source: env.source ?? "worker", severity: sev, line: env.line ?? "", lineIndex: env.lineIndex ?? 0, timestamp: ts)
        case "warning":
            return .warning(code: env.code ?? "warning", summary: env.summary ?? "", lineIndex: env.lineIndex ?? 0, timestamp: ts)
        case "metrics":
            if let m = env.metrics {
                return .metrics(m, timestamp: ts)
            }
            return nil
        case "error":
            return .error(code: env.code ?? "error", message: env.message ?? "Unknown error", timestamp: ts)
        case "result":
            if let probe = env.probe {
                return .probeResult(probe)
            }
            if let versions = env.versions {
                return .selfCheckResult(
                    WorkerSelfCheckResult(
                        ok: env.ok ?? true,
                        versions: versions,
                        tools: env.tools ?? [:],
                        headlessVerified: env.headlessVerified ?? true
                    )
                )
            }
            if let syncedFiles = env.syncedFiles {
                return .jobResult(
                    WorkerJobResult(
                        ok: env.ok ?? true,
                        syncedFiles: syncedFiles,
                        mergedFilepath: env.mergedFilepath,
                        mergeSucceeded: env.mergeSucceeded ?? false,
                        hasWarnings: env.hasWarnings ?? false,
                        warnings: env.warnings ?? [],
                        metrics: env.metrics,
                        sushiLogPath: env.sushiLogPath,
                        mergeLogPath: env.mergeLogPath
                    )
                )
            }
            return nil
        default:
            return nil
        }
    }
}
