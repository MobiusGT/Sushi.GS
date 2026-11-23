import Foundation
import SushiGSKit

enum WorkerClientError: LocalizedError {
    case workerScriptMissing
    case pythonRuntimeMissing
    case probeFailed(String)
    case selfCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .workerScriptMissing:
            "Bundled worker.py could not be found in Sushi.GS.app Resources."
        case .pythonRuntimeMissing:
            "Managed Python 3.13 environment is not installed yet. Install Required Dependencies first."
        case let .probeFailed(msg):
            "Unable to inspect media tracks: \(msg)"
        case let .selfCheckFailed(msg):
            "Worker compatibility self-check failed: \(msg)"
        }
    }
}

/// Invokes the bundled `Resources/worker.py` via the app-managed `uv` Python 3.13 venv.
/// Always resolves `worker.py` via `Bundle.main` — never relies on source-repo paths or CWD.
final class WorkerClient {
    let paths: AppPaths
    private let activeHandle = ActiveProcessHandle()

    init(paths: AppPaths) {
        self.paths = paths
    }

    static func bundledWorkerURL() -> URL? {
        if let url = Bundle.main.url(forResource: "worker", withExtension: "py") {
            return url
        }
        // Fallback when running the built binary inside Sushi.GS.app/Contents/MacOS/SushiGS directly.
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let bundleResources = execDir.deletingLastPathComponent().appendingPathComponent("Resources/worker.py")
        if FileManager.default.isReadableFile(atPath: bundleResources.path) {
            return bundleResources
        }
        return nil
    }

    private func workerEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["QT_QPA_PLATFORM"] = "offscreen"
        env["QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM"] = "1"
        env["MPLBACKEND"] = "Agg"
        return env
    }

    func cancelActiveJob() {
        activeHandle.terminate()
    }

    func runSelfCheck(config: AppConfiguration) async throws -> WorkerSelfCheckResult {
        guard let workerURL = Self.bundledWorkerURL() else {
            throw WorkerClientError.workerScriptMissing
        }
        let python = paths.venvPython
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw WorkerClientError.pythonRuntimeMissing
        }

        let resolver = BinaryResolver(paths: paths, overrides: config.binaryOverrides)
        var args = ["-u", workerURL.path, "self-check"]
        for dir in resolver.resolvedBinDirectories() {
            args.append(contentsOf: ["--bin-dir", dir])
        }
        for (k, v) in config.binaryOverrides where !v.isEmpty {
            args.append(contentsOf: ["--tool", "\(k)=\(v)"])
        }

        let result = try await ProcessRunner.runCapture(
            executable: python,
            arguments: args,
            environment: workerEnvironment()
        )
        for line in result.stdout.split(separator: "\n").map(String.init) {
            if let event = WorkerEventParser.parse(line: line) {
                switch event {
                case let .selfCheckResult(check):
                    return check
                case let .error(_, message, _):
                    throw WorkerClientError.selfCheckFailed(message)
                default:
                    break
                }
            }
        }
        let errText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw WorkerClientError.selfCheckFailed(errText.isEmpty ? "Exit code \(result.exitCode)" : errText)
    }

    /// Probes a media file using `worker.py probe` when the venv is available,
    /// falling back gracefully to direct `ffprobe` JSON parsing if Python isn't installed yet.
    func probeMedia(fileURL: URL, config: AppConfiguration) async throws -> MediaProbeResult {
        let python = paths.venvPython
        if let workerURL = Self.bundledWorkerURL(), FileManager.default.isExecutableFile(atPath: python.path) {
            let resolver = BinaryResolver(paths: paths, overrides: config.binaryOverrides)
            var args = ["-u", workerURL.path, "probe", "--file", fileURL.path]
            for dir in resolver.resolvedBinDirectories() {
                args.append(contentsOf: ["--bin-dir", dir])
            }
            for (k, v) in config.binaryOverrides where !v.isEmpty {
                args.append(contentsOf: ["--tool", "\(k)=\(v)"])
            }
            let result = try await ProcessRunner.runCapture(
                executable: python,
                arguments: args,
                environment: workerEnvironment()
            )
            for line in result.stdout.split(separator: "\n").map(String.init) {
                if let event = WorkerEventParser.parse(line: line) {
                    switch event {
                    case let .probeResult(probe):
                        return probe
                    case let .error(_, msg, _):
                        throw WorkerClientError.probeFailed(msg)
                    default:
                        break
                    }
                }
            }
        }

        // Direct ffprobe fallback before Python venv provisioning completes.
        return try await probeDirectlyWithFFprobe(fileURL: fileURL, config: config)
    }

    private func probeDirectlyWithFFprobe(fileURL: URL, config: AppConfiguration) async throws -> MediaProbeResult {
        let resolver = BinaryResolver(paths: paths, overrides: config.binaryOverrides)
        guard let ffprobe = resolver.resolveExecutable(named: "ffprobe") else {
            throw WorkerClientError.probeFailed("ffprobe is not installed yet.")
        }
        let res = try await ProcessRunner.runCapture(
            executable: ffprobe,
            arguments: [
                "-v", "quiet",
                "-print_format", "json=compact=1",
                "-show_format", "-show_streams", "-show_chapters",
                fileURL.path,
            ]
        )
        guard res.exitCode == 0,
              let data = res.stdout.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkerClientError.probeFailed("ffprobe could not read \(fileURL.lastPathComponent).")
        }

        let fmt = raw["format"] as? [String: Any] ?? [:]
        let chapters = raw["chapters"] as? [[String: Any]] ?? []
        let streams = raw["streams"] as? [[String: Any]] ?? []
        let subExtMap = ["ass": ".ass", "subrip": ".srt", "ssa": ".ssa"]

        var videoTracks: [VideoTrack] = []
        var audioTracks: [AudioTrack] = []
        var subtitleTracks: [SubtitleTrack] = []

        for s in streams {
            let ctype = s["codec_type"] as? String ?? ""
            let idx = s["index"] as? Int ?? 0
            let codec = s["codec_name"] as? String ?? ""
            let tags = s["tags"] as? [String: Any] ?? [:]
            let disp = s["disposition"] as? [String: Any] ?? [:]
            let title = tags["title"] as? String ?? ""
            let lang = tags["language"] as? String ?? "und"
            let isDefault = (disp["default"] as? Int ?? 0) == 1
            let isForced = (disp["forced"] as? Int ?? 0) == 1

            switch ctype {
            case "video":
                videoTracks.append(
                    VideoTrack(
                        id: idx, codec: codec,
                        width: s["width"] as? Int ?? 0,
                        height: s["height"] as? Int ?? 0,
                        default: isDefault, title: title
                    )
                )
            case "audio":
                let sr = (s["sample_rate"] as? String).flatMap(Int.init) ?? (s["sample_rate"] as? Int)
                let bits = (s["bits_per_raw_sample"] as? String).flatMap(Int.init) ?? (s["bits_per_raw_sample"] as? Int)
                let layout = s["channel_layout"] as? String ?? ""
                let ch = s["channels"] as? Int ?? 0
                audioTracks.append(
                    AudioTrack(
                        id: idx, codec: codec, lang: lang, title: title,
                        channelLayout: layout, channels: ch, sampleRate: sr, bitDepth: bits,
                        default: isDefault, forced: isForced
                    )
                )
            case "subtitle":
                let ext = subExtMap[codec]
                subtitleTracks.append(
                    SubtitleTrack(
                        id: idx, codec: codec, lang: lang, title: title,
                        extensionName: ext ?? "", supported: ext != nil,
                        default: isDefault, forced: isForced
                    )
                )
            default:
                break
            }
        }

        let duration = (fmt["duration"] as? String).flatMap(Double.init)
        return MediaProbeResult(
            filepath: fileURL.path,
            filename: fileURL.lastPathComponent,
            formatName: fmt["format_name"] as? String ?? "",
            durationSeconds: duration,
            chapterCount: chapters.count,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks
        )
    }

    func runJob(
        payload: WorkerJobPayload,
        onEvent: @escaping @MainActor (WorkerEvent) -> Void
    ) async throws -> Int32 {
        guard let workerURL = Self.bundledWorkerURL() else {
            throw WorkerClientError.workerScriptMissing
        }
        let python = paths.venvPython
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw WorkerClientError.pythonRuntimeMissing
        }

        let stdinData = try JSONEncoder().encode(payload)
        return try await ProcessRunner.runStreaming(
            executable: python,
            arguments: ["-u", workerURL.path, "run-job"],
            environment: workerEnvironment(),
            stdinData: stdinData,
            handle: activeHandle,
            mergeStderrIntoStdout: false,
            onLine: { @Sendable line in
                if let event = WorkerEventParser.parse(line: line) {
                    Task { @MainActor in onEvent(event) }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Task { @MainActor in
                        onEvent(.log(source: "worker", severity: .info, line: line, lineIndex: 0, timestamp: ""))
                    }
                }
            },
            onStderrLine: { @Sendable line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                Task { @MainActor in
                    onEvent(.log(source: "worker-stderr", severity: .warning, line: line, lineIndex: 0, timestamp: ""))
                }
            }
        )
    }
}
