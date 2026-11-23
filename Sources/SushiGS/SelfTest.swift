import AppKit
import Foundation
import SushiGSKit

/// In-app self-test launched via `--selftest` against an isolated `APP_STORE` in `/tmp`.
enum SelfTest {
    static func runAll() -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0

        func check(_ name: String, _ condition: Bool, detail: String = "") {
            if condition {
                print("PASS \(name)")
            } else {
                failures += 1
                print("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
            }
        }

        // 1. Bundle identity checks
        let bundleName = Bundle.main.infoDictionary?["CFBundleName"] as? String
        let displayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
        let bundleID = Bundle.main.bundleIdentifier
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        check("bundle CFBundleName == Sushi.GS", bundleName == "Sushi.GS", detail: "got \(bundleName ?? "nil")")
        check("bundle CFBundleDisplayName == Sushi.GS", displayName == "Sushi.GS", detail: "got \(displayName ?? "nil")")
        check("bundle identifier == io.github.mobiusgt.sushigs", bundleID == "io.github.mobiusgt.sushigs", detail: "got \(bundleID ?? "nil")")
        check("bundle version == 0.1.0", shortVersion == "0.1.0", detail: "got \(shortVersion ?? "nil")")

        // 2. Bundled Resources verification
        let workerURL = WorkerClient.bundledWorkerURL()
        check("bundled worker.py resolved via Bundle.main", workerURL != nil && FileManager.default.isReadableFile(atPath: workerURL!.path))
        let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        check("bundled AppIcon.icns present", icnsURL != nil)
        let carURL = Bundle.main.url(forResource: "Assets", withExtension: "car")
        check("bundled Assets.car present", carURL != nil)

        // 3. Verify all SF Symbols used in sidebar, settings, and status badges exist on macOS 26
        let symbols = SidebarDestination.allCases.map(\.symbol)
            + SettingsTab.allCases.map(\.symbol)
            + [JobStatus.pending, .running, .succeeded, .warned, .failed, .cancelled].map(\.symbolName)
            + [
                "waveform", "captions.bubble", "film.stack", "sidebar.trailing", "sparkles.tv",
                "exclamationmark.triangle.fill", "doc.badge.plus", "folder.badge.plus",
                "play.fill", "pause.fill", "stop.fill", "arrow.counterclockwise",
                "checkmark.circle", "checkmark.circle.fill", "exclamationmark.circle",
                "plus", "clock", "ellipsis.circle", "slider.horizontal.3",
                "questionmark.circle", "xmark",
            ]
        let missingSymbols = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        check("all SF Symbols valid", missingSymbols.isEmpty, detail: missingSymbols.joined(separator: ", "))

        // 4. Isolated store persistence & presets check
        let paths = AppPaths.current()
        check("isolated APP_STORE active", paths.isOverridden, detail: paths.rootDir.path)
        let model = AppModel(paths: paths)
        model.saveCurrentAsPreset(named: "SelfTest Preset")
        check("preset saved", model.presets.contains { $0.name == "SelfTest Preset" })

        // 5. Episode pairing (exact auto-verify vs regex unverified), flag mapping, & warning analyzer checks
        let exactPaired = EpisodePairing.pairFiles(
            sources: [URL(fileURLWithPath: "/src/Show - 01.mkv")],
            targets: [URL(fileURLWithPath: "/dst/Show - 01.mp4")]
        )
        check(
            "exact filename stem auto-verified",
            exactPaired.count == 1 && exactPaired[0].matchKind == .exactFilename && exactPaired[0].isVerified
        )

        let regexPaired = EpisodePairing.pairFiles(
            sources: [URL(fileURLWithPath: "/src/Show - 01 [1080p].mkv")],
            targets: [URL(fileURLWithPath: "/dst/Show.S01E01.BluRay.mkv")]
        )
        check(
            "regex episode pairing starts unverified",
            regexPaired.count == 1 && regexPaired[0].matchKind == .episodeRegex && !regexPaired[0].isVerified
        )

        let seasonConflict = EpisodePairing.pairFiles(
            sources: [URL(fileURLWithPath: "/src/Show.S01E05.mkv")],
            targets: [URL(fileURLWithPath: "/dst/Show.S02E05.mkv")]
        )
        check(
            "different explicit seasons never match",
            seasonConflict.count == 2 && seasonConflict.allSatisfy { $0.matchKind == .unmatched }
        )

        var sync = SyncSettings()
        sync.advancedArgs.window = 14
        sync.advancedArgs.maxWindow = 45
        sync.grouping = false
        let cliArgs = sync.sushiCLIArguments()
        check(
            "sushi CLI flag mapping",
            cliArgs.contains("--sample-rate") && cliArgs.contains("--window") && cliArgs.contains("--max-window") && cliArgs.contains("--no-grouping")
        )

        let analysis = WarningAnalyzer().analyze(lines: [
            "Warning: Detected possibly broken segment starting at 0:05:00.00, increasing the window from 10 to 30",
            "Total average shift: 1.250s",
        ])
        check("warning parser flags max-window fallback", analysis.hasWarnings && analysis.metrics.maxWindowHits == 1)

        return failures == 0 ? 0 : 1
    }
}
