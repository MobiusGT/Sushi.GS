import Foundation

/// Centralizes all mutable runtime paths strictly inside
/// `~/Library/Application Support/Sushi.GS/` (or `APP_STORE` during tests/snapshots)
/// so the app works even when `/Applications/Sushi.GS.app` is read-only or translocated.
public struct AppPaths: Sendable {
    public static let appSupportFolderName = "Sushi.GS"

    public let rootDir: URL
    public let isOverridden: Bool

    public init(rootDir: URL, isOverridden: Bool = false) {
        self.rootDir = rootDir
        self.isOverridden = isOverridden
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let override = environment["APP_STORE"], !override.isEmpty {
            return AppPaths(rootDir: URL(fileURLWithPath: override, isDirectory: true), isOverridden: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppPaths(rootDir: base.appendingPathComponent(appSupportFolderName, isDirectory: true), isOverridden: false)
    }

    public var binDir: URL { rootDir.appendingPathComponent("bin", isDirectory: true) }
    public var pythonDir: URL { rootDir.appendingPathComponent("python", isDirectory: true) }
    public var venvDir: URL { rootDir.appendingPathComponent("venv", isDirectory: true) }
    public var venvPython: URL { venvDir.appendingPathComponent("bin/python3") }
    public var uvBinary: URL { binDir.appendingPathComponent("uv") }
    public var toolsDir: URL { rootDir.appendingPathComponent("tools", isDirectory: true) }
    public var logsDir: URL { rootDir.appendingPathComponent("logs", isDirectory: true) }
    public var presetsDir: URL { rootDir.appendingPathComponent("presets", isDirectory: true) }
    public var runtimeDataDir: URL { rootDir.appendingPathComponent("runtime-data", isDirectory: true) }
    public var configFile: URL { rootDir.appendingPathComponent("config.json") }
    public var presetsFile: URL { presetsDir.appendingPathComponent("presets.json") }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [rootDir, binDir, pythonDir, toolsDir, logsDir, presetsDir, runtimeDataDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Identifies each managed or external CLI dependency.
public enum DependencyID: String, CaseIterable, Codable, Sendable, Identifiable {
    case uv
    case python
    case sushiBatch = "sushi-batch"
    case ffmpeg
    case ffprobe
    case mkvmerge
    case opusenc
    case aegisubCLI = "aegisub-cli"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .uv: "uv"
        case .python: "Python 3.13"
        case .sushiBatch: "sushi-batch & sushi-sub-next"
        case .ffmpeg: "FFmpeg"
        case .ffprobe: "FFprobe"
        case .mkvmerge: "MKVMerge"
        case .opusenc: "opusenc"
        case .aegisubCLI: "Aegisub-CLI"
        }
    }

    public var isRequired: Bool {
        switch self {
        case .uv, .python, .sushiBatch, .ffmpeg, .ffprobe: true
        case .mkvmerge, .opusenc, .aegisubCLI: false
        }
    }

    public var executableName: String? {
        switch self {
        case .uv: "uv"
        case .ffmpeg: "ffmpeg"
        case .ffprobe: "ffprobe"
        case .mkvmerge: "mkvmerge"
        case .opusenc: "opusenc"
        case .aegisubCLI: "aegisub-cli"
        case .python, .sushiBatch: nil
        }
    }

    public var unlocksSummary: String {
        switch self {
        case .uv: "Provisions isolated Python 3.13 and installs sushi-batch without Homebrew."
        case .python: "Managed Python 3.13 runtime for the headless Sushi worker."
        case .sushiBatch: "Core audio-based subtitle retiming and batch processing engine."
        case .ffmpeg: "Demuxes audio/subtitles and encodes lossless audio (AAC, EAC-3, libopus)."
        case .ffprobe: "Inspects video, audio, and embedded subtitle tracks."
        case .mkvmerge: "Enables automatic and manual MKV merging with chapters, fonts, and flags."
        case .opusenc: "Optional Xiph Opus encoder (FFmpeg libopus works even without it)."
        case .aegisubCLI: "Enables subtitle resolution resampling before MKV merging."
        }
    }
}

/// Resolves executable paths consistently across app-managed `bin/`, manual overrides,
/// Homebrew, and `PATH`.
public struct BinaryResolver: Sendable {
    public let paths: AppPaths
    public let overrides: [String: String]
    public let environmentPath: String

    public init(
        paths: AppPaths,
        overrides: [String: String] = [:],
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.paths = paths
        self.overrides = overrides
        self.environmentPath = environmentPath
    }

    public func resolveExecutable(named name: String, overrideKey: String? = nil) -> URL? {
        let fm = FileManager.default
        let key = overrideKey ?? name
        if let custom = overrides[key], !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }

        let managedCandidate = paths.binDir.appendingPathComponent(name)
        if fm.isExecutableFile(atPath: managedCandidate.path) {
            return managedCandidate
        }

        var searchDirs: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        for seg in environmentPath.split(separator: ":").map(String.init) where !seg.isEmpty {
            if !searchDirs.contains(seg) {
                searchDirs.append(seg)
            }
        }

        for dir in searchDirs {
            let candidate = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public func resolvedBinDirectories() -> [String] {
        var dirs: [String] = [paths.binDir.path]
        for value in overrides.values where !value.isEmpty {
            let parent = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).deletingLastPathComponent().path
            if !dirs.contains(parent) {
                dirs.append(parent)
            }
        }
        for standard in ["/opt/homebrew/bin", "/usr/local/bin"] where !dirs.contains(standard) {
            dirs.append(standard)
        }
        return dirs
    }
}
