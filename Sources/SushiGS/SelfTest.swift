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

        // 1. Bundle identity & version checks
        let bundleName = Bundle.main.infoDictionary?["CFBundleName"] as? String
        let displayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
        let bundleID = Bundle.main.bundleIdentifier
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        check("bundle CFBundleName == Sushi.GS", bundleName == "Sushi.GS", detail: "got \(bundleName ?? "nil")")
        check("bundle CFBundleDisplayName == Sushi.GS", displayName == "Sushi.GS", detail: "got \(displayName ?? "nil")")
        check("bundle identifier == io.github.mobiusgt.sushigs", bundleID == "io.github.mobiusgt.sushigs", detail: "got \(bundleID ?? "nil")")
        check("bundle version == 0.1.1", shortVersion == "0.1.1", detail: "got \(shortVersion ?? "nil")")
        check("bundle build == 2", buildNumber == "2", detail: "got \(buildNumber ?? "nil")")

        // 2. Bundled Resources verification
        let workerURL = WorkerClient.bundledWorkerURL()
        check("bundled worker.py resolved via Bundle.main", workerURL != nil && FileManager.default.isReadableFile(atPath: workerURL!.path))
        let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        check("bundled AppIcon.icns present", icnsURL != nil)
        let carURL = Bundle.main.url(forResource: "Assets", withExtension: "car")
        check("bundled Assets.car present", carURL != nil)

        // 3. Sidebar structure check
        let sidebarTitles = SidebarDestination.allCases.map(\.title)
        check(
            "sidebar has 4 expected sections",
            sidebarTitles == ["Single Episode", "Auto Batch", "Manual Batch", "Dependencies"],
            detail: sidebarTitles.joined(separator: ", ")
        )

        // 4. Verify all SF Symbols used across the app exist on macOS 26
        let symbols = SidebarDestination.allCases.map(\.symbol)
            + SettingsTab.allCases.map(\.symbol)
            + [JobStatus.pending, .running, .succeeded, .warned, .failed, .cancelled].map(\.symbolName)
            + [
                "waveform", "captions.bubble", "film.stack", "sidebar.trailing", "sparkles.tv",
                "exclamationmark.triangle.fill", "doc.badge.plus", "folder.badge.plus",
                "play.fill", "pause.fill", "stop.fill", "arrow.counterclockwise",
                "checkmark.circle", "checkmark.circle.fill", "exclamationmark.circle",
                "plus", "clock", "ellipsis.circle", "slider.horizontal.3",
                "questionmark.circle", "xmark", "arrow.right.circle", "folder", "folder.fill",
                "chevron.right", "chevron.down", "arrow.turn.left.up", "arrow.up.arrow.down",
                "arrow.uturn.down", "trash", "line.3.horizontal", "rectangle.dashed",
                "doc", "doc.on.doc", "doc.text.magnifyingglass", "arrow.clockwise",
            ]
        let missingSymbols = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        check("all SF Symbols valid", missingSymbols.isEmpty, detail: missingSymbols.joined(separator: ", "))

        // 5. Isolated store persistence & presets check
        let paths = AppPaths.current()
        check("isolated APP_STORE active", paths.isOverridden, detail: paths.rootDir.path)
        let model = AppModel(paths: paths)
        model.saveCurrentAsPreset(named: "SelfTest Preset")
        check("preset saved", model.presets.contains { $0.name == "SelfTest Preset" })

        // 6. Auto Batch 3-way External Subtitle pairing & Continue to Queue checks
        let exact3Way = EpisodePairing.pairFiles(
            sources: [URL(fileURLWithPath: "/src/Show - 01.mkv")],
            targets: [URL(fileURLWithPath: "/dst/Show - 01.mp4")],
            externalSubtitles: [URL(fileURLWithPath: "/sub/Show - 01.ass")],
            subtitleMode: .external
        )
        check(
            "3-way exact stem auto-verified in External mode",
            exact3Way.count == 1 && exact3Way[0].matchKind == .exactFilename && exact3Way[0].isVerified && exact3Way[0].externalSubtitleFile != nil
        )

        let heuristicSub3Way = EpisodePairing.pairFiles(
            sources: [URL(fileURLWithPath: "/src/Show - 01.mkv")],
            targets: [URL(fileURLWithPath: "/dst/Show - 01.mp4")],
            externalSubtitles: [URL(fileURLWithPath: "/sub/[Group] Show S01E01.ass")],
            subtitleMode: .external
        )
        check(
            "3-way heuristic subtitle starts unverified in External mode",
            heuristicSub3Way.count == 1 && heuristicSub3Way[0].externalSubtitleFile != nil && !heuristicSub3Way[0].isVerified
        )

        let seasonConflict = EpisodePairing.pairFiles(
            sources: [URL(fileURLWithPath: "/src/Show.S01E05.mkv")],
            targets: [URL(fileURLWithPath: "/dst/Show.S02E05.mkv")],
            externalSubtitles: [URL(fileURLWithPath: "/sub/Show.S02E05.ass")],
            subtitleMode: .external
        )
        check(
            "season conflict rejects S01 vs S02 media while pairing S02 target with S02 subtitle",
            seasonConflict.count == 2
                && seasonConflict.contains(where: { $0.sourceFile != nil && $0.targetFile == nil && $0.externalSubtitleFile == nil })
                && seasonConflict.contains(where: { $0.sourceFile == nil && $0.targetFile != nil && $0.externalSubtitleFile != nil })
        )

        // Continue to Queue with 0 folders opens 1 blank row
        model.clearBatchQueue()
        model.continueToAutoBatchQueue()
        check(
            "Continue to Queue with 0 folders creates 1 blank row",
            model.isBatchInQueueStage && model.batchJobs.count == 1 && model.batchJobs[0].sourceURL == nil && model.batchJobs[0].targetURL == nil
        )

        // Continue to Queue with 1 folder populates all files from that folder
        model.clearBatchQueue()
        model.stageBatchInput(
            [
                URL(fileURLWithPath: "/src/Show - 01.mkv"),
                URL(fileURLWithPath: "/src/Show - 02.mkv"),
            ],
            slot: .sourceMedia,
            replaceExisting: true
        )
        check("1 staged folder stays on Stage 1 intake", !model.isBatchInQueueStage)
        model.continueToAutoBatchQueue()
        check(
            "Continue to Queue with 1 folder populates Stage 2 rows",
            model.isBatchInQueueStage && model.batchJobs.count == 2 && model.batchJobs.allSatisfy { $0.sourceURL != nil && $0.targetURL == nil }
        )

        // 7. Manual Batch strict row-by-row pairing, blank slot & Embedded/External completeness check
        model.clearManualBatch()
        model.setManualSubtitleMode(.external)
        model.manualInsert(
            urls: [URL(fileURLWithPath: "/a/Totally_Unrelated_A.mkv"), URL(fileURLWithPath: "/a/Totally_Unrelated_B.mkv")],
            into: .sourceVideo,
            expandDirectories: false
        )
        model.manualInsert(
            urls: [URL(fileURLWithPath: "/b/Zebra.mkv"), URL(fileURLWithPath: "/b/Alpha.mkv")],
            into: .targetVideo,
            expandDirectories: false
        )
        model.manualInsert(
            urls: [URL(fileURLWithPath: "/c/Sub1.ass")],
            into: .sourceSubtitle,
            expandDirectories: false
        )
        model.manualInsertBlankSlot(in: .sourceSubtitle, at: 0)
        check(
            "Manual Batch pairs strictly by row index and tracks blank-slot incompleteness",
            model.manualColumns.rowCount == 2
                && !model.manualColumns.row(at: 0).isComplete
                && model.manualColumns.row(at: 1).isComplete
                && model.manualColumns.row(at: 1).sourceURL?.lastPathComponent == "Totally_Unrelated_B.mkv"
                && model.manualColumns.row(at: 1).subtitleURL?.lastPathComponent == "Sub1.ass"
                && model.manualColumns.row(at: 1).targetURL?.lastPathComponent == "Alpha.mkv"
        )

        // 8. CLI flag mapping & warning analyzer checks
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
