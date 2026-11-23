import Foundation
import Observation
import SushiGSKit

enum DependencyState: Equatable {
    case checking
    case installed
    case updateAvailable(latest: String)
    case missing
    case installing(step: String)
    case failed(String)

    var isReady: Bool {
        switch self {
        case .installed, .updateAvailable: true
        default: false
        }
    }

    var badgeText: String {
        switch self {
        case .checking: "Checking…"
        case .installed: "Installed"
        case let .updateAvailable(latest): "Update \(latest)"
        case .missing: "Missing"
        case let .installing(step): step
        case .failed: "Error"
        }
    }
}

struct DependencyRecord: Identifiable {
    let id: DependencyID
    var state: DependencyState = .checking
    var version: String?
    var resolvedPath: String?
    var detail: String = ""
    var isManagedByApp: Bool = false
}

/// First-class in-app Dependency Manager & one-click updater.
/// Installs `uv`, managed Python 3.13, `sushi-batch` (+ `sushi-sub-next`), standalone `arm64`
/// `ffmpeg`/`ffprobe`, `mkvmerge` (MKVToolNix), and Homebrew-assisted `opusenc` directly inside
/// `~/Library/Application Support/Sushi.GS/` without requiring Terminal or Xcode.
@Observable
final class DependencyManager {
    let paths: AppPaths
    private let workerClient: WorkerClient

    private(set) var records: [DependencyID: DependencyRecord] = Dictionary(
        uniqueKeysWithValues: DependencyID.allCases.map { ($0, DependencyRecord(id: $0)) }
    )
    private(set) var isBusy = false
    private(set) var activeTaskDescription: String?
    private(set) var installLogs: [String] = []
    private(set) var lastSelfCheck: WorkerSelfCheckResult?
    var showInstallLog = false
    var showAegisubGuide = false
    var showOpusencGuide = false

    init(paths: AppPaths, workerClient: WorkerClient) {
        self.paths = paths
        self.workerClient = workerClient
    }

    var orderedRequired: [DependencyRecord] {
        DependencyID.allCases.filter(\.isRequired).compactMap { records[$0] }
    }

    var orderedOptional: [DependencyRecord] {
        DependencyID.allCases.filter { !$0.isRequired }.compactMap { records[$0] }
    }

    var missingRequiredDependencies: [DependencyRecord] {
        orderedRequired.filter { !$0.state.isReady }
    }

    var allRequiredReady: Bool {
        missingRequiredDependencies.isEmpty
    }

    func isInstalled(_ id: DependencyID) -> Bool {
        records[id]?.state.isReady == true
    }

    var hasHomebrew: Bool {
        brewExecutableURL() != nil
    }

    private func brewExecutableURL() -> URL? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func appendLog(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        installLogs.append("[\(stamp)] \(line)")
        if installLogs.count > 2000 {
            installLogs.removeFirst(installLogs.count - 2000)
        }
    }

    func clearLogs() {
        installLogs.removeAll()
    }

    /// Seed synthetic ready state for UI snapshots without network calls or personal paths.
    func applySeededPreviewState() {
        let appSupport = "~/Library/Application Support/Sushi.GS"
        records[.uv] = DependencyRecord(
            id: .uv, state: .installed, version: "0.13.9",
            resolvedPath: "\(appSupport)/bin/uv", detail: "App-managed arm64 binary", isManagedByApp: true
        )
        records[.python] = DependencyRecord(
            id: .python, state: .installed, version: "3.13.18",
            resolvedPath: "\(appSupport)/venv/bin/python3", detail: "Managed uv Python 3.13 venv", isManagedByApp: true
        )
        records[.sushiBatch] = DependencyRecord(
            id: .sushiBatch, state: .installed, version: "1.1.0 (sushi-sub-next 0.6.7)",
            resolvedPath: "\(appSupport)/venv", detail: "Headless worker self-check passed", isManagedByApp: true
        )
        records[.ffmpeg] = DependencyRecord(
            id: .ffmpeg, state: .installed, version: "7.1.1",
            resolvedPath: "\(appSupport)/bin/ffmpeg",
            detail: "Native Apple Silicon binary", isManagedByApp: true
        )
        records[.ffprobe] = DependencyRecord(
            id: .ffprobe, state: .installed, version: "7.1.1",
            resolvedPath: "\(appSupport)/bin/ffprobe",
            detail: "Native Apple Silicon binary", isManagedByApp: true
        )
        records[.mkvmerge] = DependencyRecord(
            id: .mkvmerge, state: .installed, version: "91.0",
            resolvedPath: "\(appSupport)/bin/mkvmerge", detail: "MKV merging enabled", isManagedByApp: true
        )
        records[.opusenc] = DependencyRecord(
            id: .opusenc, state: .missing, version: nil, resolvedPath: nil,
            detail: "Optional — FFmpeg libopus is already available", isManagedByApp: false
        )
        records[.aegisubCLI] = DependencyRecord(
            id: .aegisubCLI, state: .missing, version: nil, resolvedPath: nil,
            detail: "Optional — no official macOS arm64 prebuilt binary; build or pick custom path", isManagedByApp: false
        )
    }

    // MARK: - Refresh & Verify All

    func refreshAll(config: AppConfiguration, checkRemoteUpdates: Bool = true) async {
        let resolver = BinaryResolver(paths: paths, overrides: config.binaryOverrides)

        // 1. Check uv
        await checkExecutable(.uv, versionArgs: ["--version"], resolver: resolver) { output in
            output.replacingOccurrences(of: "uv ", with: "").split(separator: " ").first.map(String.init)
        }

        // 2. Check Python 3.13 venv
        let venvPy = paths.venvPython
        if FileManager.default.isExecutableFile(atPath: venvPy.path) {
            if let res = try? await ProcessRunner.runCapture(executable: venvPy, arguments: ["--version"]),
               res.exitCode == 0 {
                let ver = (res.stdout + res.stderr)
                    .replacingOccurrences(of: "Python ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                records[.python] = DependencyRecord(
                    id: .python,
                    state: .installed,
                    version: ver,
                    resolvedPath: venvPy.path,
                    detail: "Managed uv Python venv",
                    isManagedByApp: true
                )
            } else {
                records[.python] = DependencyRecord(id: .python, state: .missing, detail: "Venv Python unreadable")
            }
        } else {
            records[.python] = DependencyRecord(id: .python, state: .missing, detail: "Provisioned automatically via uv")
        }

        // 3. Check fast CLI binaries (FFmpeg, FFprobe, MKVMerge, opusenc, aegisub-cli) first
        await checkExecutable(.ffmpeg, versionArgs: ["-version"], resolver: resolver) { output in
            Self.parseFFmpegVersion(output)
        }
        await checkExecutable(.ffprobe, versionArgs: ["-version"], resolver: resolver) { output in
            Self.parseFFmpegVersion(output)
        }
        await checkExecutable(.mkvmerge, versionArgs: ["--version"], resolver: resolver) { output in
            Self.parseMKVMergeVersion(output)
        }
        await checkExecutable(.opusenc, versionArgs: ["--version"], resolver: resolver) { output in
            output.split(separator: "\n").first.map(String.init)
        }
        await checkExecutable(.aegisubCLI, versionArgs: ["--help"], resolver: resolver, acceptNonZeroExit: true) { _ in
            "Installed"
        }

        // 4. Check sushi-batch & sushi-sub-next via worker self-check (local first, PyPI check asynchronously)
        var installedSushiBatchVersion: String?
        if records[.python]?.state.isReady == true {
            do {
                let check = try await workerClient.runSelfCheck(config: config)
                lastSelfCheck = check
                let sbVer = check.versions["sushi_batch"] ?? "unknown"
                let snVer = check.versions["sushi_sub_next"] ?? "unknown"
                installedSushiBatchVersion = sbVer
                records[.sushiBatch] = DependencyRecord(
                    id: .sushiBatch,
                    state: .installed,
                    version: "\(sbVer) (sushi-next \(snVer))",
                    resolvedPath: paths.venvDir.path,
                    detail: check.headlessVerified ? "Headless self-check passed" : "Self-check passed",
                    isManagedByApp: true
                )
            } catch {
                records[.sushiBatch] = DependencyRecord(
                    id: .sushiBatch,
                    state: .missing,
                    detail: error.localizedDescription
                )
            }
        } else {
            records[.sushiBatch] = DependencyRecord(
                id: .sushiBatch,
                state: .missing,
                detail: "Requires uv & Python 3.13"
            )
        }

        // 5. Non-blocking PyPI update check for sushi-batch after local detection completes.
        if checkRemoteUpdates, let sbVer = installedSushiBatchVersion {
            Task { [weak self] in
                guard let self,
                      let latest = await self.fetchLatestPyPIVersion(package: "sushi-batch"),
                      self.compareSemVer(latest, isNewerThan: sbVer) else {
                    return
                }
                self.records[.sushiBatch]?.state = .updateAvailable(latest: latest)
            }
        }
    }

    private func checkExecutable(
        _ id: DependencyID,
        versionArgs: [String],
        resolver: BinaryResolver,
        acceptNonZeroExit: Bool = false,
        parseVersion: (String) -> String?
    ) async {
        guard let execName = id.executableName else { return }
        guard let resolved = resolver.resolveExecutable(named: execName) else {
            records[id] = DependencyRecord(
                id: id,
                state: .missing,
                detail: id == .aegisubCLI
                    ? "No prebuilt Apple Silicon binary; select a custom binary or build from source."
                    : id.unlocksSummary
            )
            return
        }

        let isManaged = resolved.path.hasPrefix(paths.rootDir.path)
        do {
            let res = try await ProcessRunner.runCapture(executable: resolved, arguments: versionArgs)
            if res.exitCode == 0 || acceptNonZeroExit {
                let combined = res.stdout.isEmpty ? res.stderr : res.stdout
                let version = parseVersion(combined) ?? "Installed"
                records[id] = DependencyRecord(
                    id: id,
                    state: .installed,
                    version: version,
                    resolvedPath: resolved.path,
                    detail: isManaged ? "App-managed binary" : "Detected on system",
                    isManagedByApp: isManaged
                )
            } else {
                records[id] = DependencyRecord(
                    id: id,
                    state: .failed("Exited with status \(res.exitCode)"),
                    resolvedPath: resolved.path,
                    detail: "Binary found at \(resolved.path) but failed check",
                    isManagedByApp: isManaged
                )
            }
        } catch {
            records[id] = DependencyRecord(
                id: id,
                state: .failed(error.localizedDescription),
                resolvedPath: resolved.path,
                detail: error.localizedDescription,
                isManagedByApp: isManaged
            )
        }
    }

    // MARK: - One-Click Installers

    func installAllRequired(config: AppConfiguration) async {
        guard !isBusy else { return }
        isBusy = true
        showInstallLog = true
        activeTaskDescription = "Installing required dependencies…"
        defer {
            isBusy = false
            activeTaskDescription = nil
        }

        do {
            try paths.ensureDirectories()
            if !isInstalled(.uv) {
                try await performInstallUV()
            }
            if !isInstalled(.python) {
                try await performProvisionPython()
            }
            if !isInstalled(.sushiBatch) {
                try await performInstallSushiBatch(config: config, reinstall: false)
            }
            if !isInstalled(.ffmpeg) || !isInstalled(.ffprobe) {
                try await performInstallFFmpegAndFFprobe()
            }
            appendLog("All required dependencies installed. Running full verification…")
            await refreshAll(config: config, checkRemoteUpdates: false)
        } catch {
            appendLog("ERROR: \(error.localizedDescription)")
            await refreshAll(config: config, checkRemoteUpdates: false)
        }
    }

    func installOrUpdate(_ id: DependencyID, config: AppConfiguration, reinstall: Bool = false, preferHomebrew: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        showInstallLog = true
        activeTaskDescription = "\(reinstall ? "Reinstalling" : "Installing") \(id.displayName)…"
        defer {
            isBusy = false
            activeTaskDescription = nil
        }

        do {
            try paths.ensureDirectories()
            switch id {
            case .uv:
                try await performInstallUV()
            case .python:
                if !isInstalled(.uv) { try await performInstallUV() }
                try await performProvisionPython(recreate: reinstall)
            case .sushiBatch:
                if !isInstalled(.uv) { try await performInstallUV() }
                if !isInstalled(.python) { try await performProvisionPython() }
                try await performInstallSushiBatch(config: config, reinstall: reinstall)
            case .ffmpeg, .ffprobe:
                if preferHomebrew, let brew = brewExecutableURL() {
                    try await runBrewInstall(brew: brew, formula: "ffmpeg", isCask: false, for: id)
                } else {
                    try await performInstallFFmpegAndFFprobe()
                }
            case .mkvmerge:
                if preferHomebrew, let brew = brewExecutableURL() {
                    try await runBrewInstall(brew: brew, formula: "mkvtoolnix", isCask: false, for: .mkvmerge)
                } else {
                    try await performInstallMKVToolNix()
                }
            case .opusenc:
                if let brew = brewExecutableURL() {
                    try await runBrewInstall(brew: brew, formula: "opus-tools", isCask: false, for: .opusenc)
                } else {
                    appendLog("Homebrew was not detected. Opening guided setup for opusenc.")
                    showOpusencGuide = true
                }
            case .aegisubCLI:
                appendLog("No official prebuilt Apple Silicon binary is published for aegisub-cli. Opening guided setup.")
                showAegisubGuide = true
            }
            await refreshAll(config: config, checkRemoteUpdates: false)
        } catch {
            records[id]?.state = .failed(error.localizedDescription)
            records[id]?.detail = error.localizedDescription
            appendLog("ERROR (\(id.displayName)): \(error.localizedDescription)")
            await refreshAll(config: config, checkRemoteUpdates: false)
        }
    }

    // MARK: - uv + Python 3.13 + sushi-batch

    private func performInstallUV() async throws {
        records[.uv]?.state = .installing(step: "Downloading uv…")
        let url = URL(string: "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz")!
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sushigs-uv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archive = tempDir.appendingPathComponent("uv.tar.gz")
        appendLog("Downloading official arm64 uv from \(url.absoluteString)")
        try await downloadFile(from: url, to: archive)

        records[.uv]?.state = .installing(step: "Extracting uv…")
        let extractDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let rc = try await ProcessRunner.runCapture(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", extractDir.path]
        )
        guard rc.exitCode == 0 else {
            throw NSError(domain: "SushiGS", code: Int(rc.exitCode), userInfo: [NSLocalizedDescriptionKey: "Failed to unpack uv archive: \(rc.stderr)"])
        }

        // Locate extracted `uv` binary (inside uv-aarch64-apple-darwin/uv or root).
        let candidates = [
            extractDir.appendingPathComponent("uv-aarch64-apple-darwin/uv"),
            extractDir.appendingPathComponent("uv"),
        ]
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw NSError(domain: "SushiGS", code: 2, userInfo: [NSLocalizedDescriptionKey: "uv executable not found inside downloaded archive."])
        }

        let dest = paths.uvBinary
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: found, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        _ = try? await ProcessRunner.runCapture(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-d", "com.apple.quarantine", dest.path])
        appendLog("Installed uv to \(dest.path)")
    }

    private func uvEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["UV_PYTHON_INSTALL_DIR"] = paths.pythonDir.path
        env["UV_CACHE_DIR"] = paths.rootDir.appendingPathComponent("uv-cache").path
        env["UV_NO_PROGRESS"] = "1"
        return env
    }

    private func performProvisionPython(recreate: Bool = false) async throws {
        let uv = BinaryResolver(paths: paths).resolveExecutable(named: "uv") ?? paths.uvBinary
        guard FileManager.default.isExecutableFile(atPath: uv.path) else {
            throw NSError(domain: "SushiGS", code: 3, userInfo: [NSLocalizedDescriptionKey: "uv binary missing."])
        }

        records[.python]?.state = .installing(step: "Installing Python 3.13…")
        appendLog("Provisioning managed Python 3.13 via uv…")
        let rcInstall = try await ProcessRunner.runStreaming(
            executable: uv,
            arguments: ["python", "install", "3.13"],
            environment: uvEnvironment(),
            mergeStderrIntoStdout: true,
            onLine: { @Sendable line in
                Task { @MainActor in self.appendLog(line) }
            }
        )
        guard rcInstall == 0 else {
            throw NSError(domain: "SushiGS", code: Int(rcInstall), userInfo: [NSLocalizedDescriptionKey: "uv python install 3.13 failed (exit \(rcInstall))."])
        }

        if recreate {
            try? FileManager.default.removeItem(at: paths.venvDir)
        }
        records[.python]?.state = .installing(step: "Creating venv…")
        appendLog("Creating isolated virtual environment at \(paths.venvDir.path)")
        let rcVenv = try await ProcessRunner.runStreaming(
            executable: uv,
            arguments: ["venv", "--python", "3.13", "--clear", paths.venvDir.path],
            environment: uvEnvironment(),
            mergeStderrIntoStdout: true,
            onLine: { @Sendable line in
                Task { @MainActor in self.appendLog(line) }
            }
        )
        guard rcVenv == 0 else {
            throw NSError(domain: "SushiGS", code: Int(rcVenv), userInfo: [NSLocalizedDescriptionKey: "uv venv creation failed (exit \(rcVenv))."])
        }
    }

    private func performInstallSushiBatch(config: AppConfiguration, reinstall: Bool) async throws {
        let uv = BinaryResolver(paths: paths).resolveExecutable(named: "uv") ?? paths.uvBinary
        records[.sushiBatch]?.state = .installing(step: "Installing sushi-batch…")

        let gitRef = config.general.sushiBatchGitRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let packageSpec = gitRef.isEmpty ? "sushi-batch" : "git+https://github.com/C1fer/sushi-batch.git@\(gitRef)"
        appendLog("Installing \(packageSpec) into managed venv via uv…")

        var args = ["pip", "install", "--python", paths.venvPython.path, "--upgrade"]
        if reinstall {
            args.append("--reinstall-package")
            args.append("sushi-batch")
        }
        args.append(packageSpec)

        let rc = try await ProcessRunner.runStreaming(
            executable: uv,
            arguments: args,
            environment: uvEnvironment(),
            mergeStderrIntoStdout: true,
            onLine: { @Sendable line in
                Task { @MainActor in self.appendLog(line) }
            }
        )
        guard rc == 0 else {
            throw NSError(domain: "SushiGS", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "uv pip install \(packageSpec) failed (exit \(rc))."])
        }

        // Run post-update compatibility self-check.
        records[.sushiBatch]?.state = .installing(step: "Running self-check…")
        appendLog("Running post-install worker compatibility self-check…")
        let check = try await workerClient.runSelfCheck(config: config)
        lastSelfCheck = check
        appendLog("Self-check passed: sushi-batch \(check.versions["sushi_batch"] ?? "?"), sushi-sub-next \(check.versions["sushi_sub_next"] ?? "?"), headless=\(check.headlessVerified)")
    }

    // MARK: - Standalone arm64 FFmpeg & FFprobe

    private func performInstallFFmpegAndFFprobe() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sushigs-ffmpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for tool in ["ffmpeg", "ffprobe"] {
            let depID: DependencyID = (tool == "ffmpeg") ? .ffmpeg : .ffprobe
            records[depID]?.state = .installing(step: "Downloading \(tool)…")
            let url = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/\(tool).zip")!
            let zipPath = tempDir.appendingPathComponent("\(tool).zip")
            appendLog("Downloading native Apple Silicon \(tool) from \(url.absoluteString)")
            try await downloadFile(from: url, to: zipPath)

            records[depID]?.state = .installing(step: "Extracting \(tool)…")
            let unzipDir = tempDir.appendingPathComponent("out-\(tool)")
            try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
            let res = try await ProcessRunner.runCapture(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-xk", zipPath.path, unzipDir.path]
            )
            guard res.exitCode == 0 else {
                throw NSError(domain: "SushiGS", code: Int(res.exitCode), userInfo: [NSLocalizedDescriptionKey: "Failed to unzip \(tool): \(res.stderr)"])
            }

            let extracted = unzipDir.appendingPathComponent(tool)
            guard FileManager.default.fileExists(atPath: extracted.path) else {
                throw NSError(domain: "SushiGS", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(tool) binary missing from zip archive."])
            }

            let dest = paths.binDir.appendingPathComponent(tool)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: extracted, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            _ = try? await ProcessRunner.runCapture(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-d", "com.apple.quarantine", dest.path])
            appendLog("Installed \(tool) to \(dest.path)")
        }
    }

    // MARK: - Official arm64 MKVToolNix DMG Installer

    private func performInstallMKVToolNix() async throws {
        records[.mkvmerge]?.state = .installing(step: "Checking latest MKVToolNix…")
        let xmlURL = URL(string: "https://mkvtoolnix.download/latest-release.xml")!
        appendLog("Fetching latest MKVToolNix release metadata from \(xmlURL.absoluteString)")
        let (data, _) = try await URLSession.shared.data(from: xmlURL)
        let xml = String(decoding: data, as: UTF8.self)

        guard let dmgURL = Self.extractArm64MKVToolNixDMGURL(from: xml) else {
            if let brew = brewExecutableURL() {
                appendLog("Could not find direct arm64 DMG URL in XML feed; falling back to Homebrew mkvtoolnix…")
                try await runBrewInstall(brew: brew, formula: "mkvtoolnix", isCask: false, for: .mkvmerge)
                return
            }
            throw NSError(
                domain: "SushiGS",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Could not locate an arm64 macOS MKVToolNix DMG URL."]
            )
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sushigs-mkv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dmgFile = tempDir.appendingPathComponent("MKVToolNix.dmg")
        records[.mkvmerge]?.state = .installing(step: "Downloading MKVToolNix…")
        appendLog("Downloading \(dmgURL.absoluteString)")
        try await downloadFile(from: dmgURL, to: dmgFile)

        let mountPoint = tempDir.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        records[.mkvmerge]?.state = .installing(step: "Extracting mkvmerge…")
        let attach = try await ProcessRunner.runCapture(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", dmgFile.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        )
        guard attach.exitCode == 0 else {
            throw NSError(domain: "SushiGS", code: Int(attach.exitCode), userInfo: [NSLocalizedDescriptionKey: "Failed to mount MKVToolNix DMG: \(attach.stderr)"])
        }
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint.path, "-quiet", "-force"]
            try? detach.run()
            detach.waitUntilExit()
        }

        let contents = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "SushiGS", code: 6, userInfo: [NSLocalizedDescriptionKey: "MKVToolNix.app not found inside DMG."])
        }

        let destBundle = paths.toolsDir.appendingPathComponent("MKVToolNix.app")
        try? FileManager.default.removeItem(at: destBundle)
        try FileManager.default.copyItem(at: appBundle, to: destBundle)
        _ = try? await ProcessRunner.runCapture(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-cr", destBundle.path])

        // Symlink mkvmerge, mkvextract, and mkvinfo into managed bin/ so PATH lookup finds them seamlessly.
        let macOSDir = destBundle.appendingPathComponent("Contents/MacOS")
        for tool in ["mkvmerge", "mkvextract", "mkvinfo"] {
            let src = macOSDir.appendingPathComponent(tool)
            let link = paths.binDir.appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: src.path) {
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: src)
            }
        }
        appendLog("Installed MKVToolNix into \(destBundle.path) and linked mkvmerge into \(paths.binDir.path)")
    }

    private func runBrewInstall(brew: URL, formula: String, isCask: Bool, for id: DependencyID) async throws {
        records[id]?.state = .installing(step: "Installing via Homebrew…")
        var args = ["install"]
        if isCask { args.append("--cask") }
        args.append(formula)
        appendLog("Running: \(brew.path) \(args.joined(separator: " "))")
        let rc = try await ProcessRunner.runStreaming(
            executable: brew,
            arguments: args,
            mergeStderrIntoStdout: true,
            onLine: { @Sendable line in
                Task { @MainActor in self.appendLog(line) }
            }
        )
        guard rc == 0 else {
            throw NSError(domain: "SushiGS", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "Homebrew install of \(formula) failed (exit \(rc))."])
        }
    }

    // MARK: - Networking & Parsing Helpers

    private func downloadFile(from url: URL, to destination: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "SushiGS",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Download failed with HTTP \(http.statusCode) from \(url.host ?? url.absoluteString)"]
            )
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func fetchLatestPyPIVersion(package: String) async -> String? {
        guard let url = URL(string: "https://pypi.org/pypi/\(package)/json") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["info"] as? [String: Any],
              let version = info["version"] as? String else {
            return nil
        }
        return version
    }

    private func compareSemVer(_ lhs: String, isNewerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").compactMap { Int($0.filter(\.isNumber)) }
        let b = rhs.split(separator: ".").compactMap { Int($0.filter(\.isNumber)) }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    static func parseFFmpegVersion(_ output: String) -> String? {
        guard let firstLine = output.split(separator: "\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        if parts.count >= 3, parts[1] == "version" {
            return String(parts[2])
        }
        return String(firstLine)
    }

    static func parseMKVMergeVersion(_ output: String) -> String? {
        guard let firstLine = output.split(separator: "\n").first else { return nil }
        if let range = firstLine.range(of: #"v\d+(?:\.\d+)+"#, options: .regularExpression) {
            return String(firstLine[range]).trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        }
        return String(firstLine)
    }

    static func extractArm64MKVToolNixDMGURL(from xml: String) -> URL? {
        let pattern = #"https://mkvtoolnix\.download/macos/releases/[^"<\s]*arm64\.dmg"#
        if let range = xml.range(of: pattern, options: .regularExpression) {
            return URL(string: String(xml[range]))
        }
        // Fallback: universal or macOS dmg link inside XML
        let fallbackPattern = #"https://mkvtoolnix\.download/macos/releases/[^"<\s]*\.dmg"#
        if let range = xml.range(of: fallbackPattern, options: .regularExpression) {
            return URL(string: String(xml[range]))
        }
        return nil
    }
}
