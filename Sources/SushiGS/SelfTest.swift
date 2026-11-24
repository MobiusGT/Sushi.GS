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
                "chevron.left", "chevron.right", "chevron.down", "arrow.up", "arrow.up.arrow.down",
                "arrow.uturn.down", "trash", "line.3.horizontal", "rectangle.dashed",
                "doc", "doc.on.doc", "doc.text.magnifyingglass", "arrow.clockwise",
            ]
        let missingSymbols = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        check("all SF Symbols valid", missingSymbols.isEmpty, detail: missingSymbols.joined(separator: ", "))

        // 5. Isolated store persistence & presets check
        let paths = AppPaths.current()
        check("isolated APP_STORE active", paths.isOverridden, detail: paths.rootDir.path)
        let model = AppModel(paths: paths)
        check("Log Inspector defaults to collapsed", model.showInspector == false)
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

        // 6b. Real-folder end-to-end AppModel Auto Batch integration tests (Stage 1 3-folder, Stage 2 Add External Subtitle Folder, symlink + nested subfolders)
        let fm = FileManager.default
        let integrationRoot = fm.temporaryDirectory.appendingPathComponent("sushigs-selftest-autobatch-\(UUID().uuidString)")
        let srcDir = integrationRoot.appendingPathComponent("Source")
        let dstDir = integrationRoot.appendingPathComponent("Target")
        let subDir = integrationRoot.appendingPathComponent("Subtitles")
        let nestedSubDir = subDir.appendingPathComponent("NestedSubs/Season1")
        let emptySubDir = integrationRoot.appendingPathComponent("EmptySubs")
        let symlinkSubDir = integrationRoot.appendingPathComponent("SubtitlesLink")
        defer { try? fm.removeItem(at: integrationRoot) }

        do {
            try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: nestedSubDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: emptySubDir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: symlinkSubDir, withDestinationURL: subDir)

            let sourceFiles = [
                "[Moozzi2] Mahou no Angel Sweet Mint - 01 (BD Remux 1080p).mkv",
                "[Moozzi2] Mahou no Angel Sweet Mint - 02 (BD Remux 1080p).mkv",
                "[Moozzi2] Mahou no Angel Sweet Mint - 03 (BD Remux 1080p).mkv",
                "[Moozzi2] Mahou no Angel Sweet Mint - Menu 01 (BD Remux 1080p).mkv",
                "[Moozzi2] Mahou no Angel Sweet Mint - NCOP (BD Remux 1080p).mkv",
            ]
            for name in sourceFiles {
                fm.createFile(atPath: srcDir.appendingPathComponent(name).path, contents: Data())
            }
            for name in ["[Stardust] 00001.mkv", "[Stardust] 00002.mkv", "[Stardust] 00003.mkv"] {
                fm.createFile(atPath: dstDir.appendingPathComponent(name).path, contents: Data())
            }
            fm.createFile(atPath: subDir.appendingPathComponent("[Stardust] 00001 complete++.ass").path, contents: Data())
            fm.createFile(atPath: subDir.appendingPathComponent("[Stardust] 00002 complete++.ASS").path, contents: Data())
            fm.createFile(atPath: nestedSubDir.appendingPathComponent("[Stardust] 00003 complete++.ass").path, contents: Data())

            func verifyThreeEpisodesPaired(in jobs: [EpisodeJob]) -> Bool {
                let expected: [(src: String, dst: String, sub: String)] = [
                    (
                        "[Moozzi2] Mahou no Angel Sweet Mint - 01 (BD Remux 1080p).mkv",
                        "[Stardust] 00001.mkv",
                        "[Stardust] 00001 complete++.ass"
                    ),
                    (
                        "[Moozzi2] Mahou no Angel Sweet Mint - 02 (BD Remux 1080p).mkv",
                        "[Stardust] 00002.mkv",
                        "[Stardust] 00002 complete++.ASS"
                    ),
                    (
                        "[Moozzi2] Mahou no Angel Sweet Mint - 03 (BD Remux 1080p).mkv",
                        "[Stardust] 00003.mkv",
                        "[Stardust] 00003 complete++.ass"
                    ),
                ]
                return expected.allSatisfy { item in
                    jobs.contains { job in
                        job.sourceURL?.lastPathComponent == item.src
                            && job.targetURL?.lastPathComponent == item.dst
                            && job.externalSubtitleURL?.lastPathComponent == item.sub
                            && job.useExternalSubtitle
                            && job.isComplete(for: .external)
                            && !job.isVerified
                    }
                }
            }

            // Flow A: Stage 1 3-folder External intake (with empty-folder guard + nested subfolder + uppercase .ASS)
            model.clearBatchQueue()
            model.batchSubtitleMode = .external
            model.stageBatchInput([srcDir], slot: .sourceMedia, replaceExisting: true)
            model.stageBatchInput([dstDir], slot: .targetMedia, replaceExisting: true)
            let stayedBeforeSubs = !model.isBatchInQueueStage
            model.stageBatchInput([emptySubDir], slot: .externalSubtitles, replaceExisting: true)
            let stayedOnEmptySubs = !model.isBatchInQueueStage
            model.stageBatchInput([subDir], slot: .externalSubtitles, replaceExisting: true)
            check(
                "AppModel Stage 1 3-folder External intake pairs Moozzi2 + Stardust + complete++.ass (incl. nested & .ASS)",
                stayedBeforeSubs
                    && stayedOnEmptySubs
                    && model.isBatchInQueueStage
                    && model.batchSubtitleMode == .external
                    && verifyThreeEpisodesPaired(in: model.batchJobs),
                detail: "jobs=\(model.batchJobs.map { "\($0.episodeBadge):\($0.sourceURL?.lastPathComponent ?? "nil")->\($0.targetURL?.lastPathComponent ?? "nil")|\($0.externalSubtitleURL?.lastPathComponent ?? "nil")" }.joined(separator: "; "))"
            )

            // Flow B: Stage 1 Embedded -> auto Stage 2 -> Stage 2 Add External Subtitle Folder
            model.clearBatchQueue()
            model.batchSubtitleMode = .embedded
            model.stageBatchInput([srcDir], slot: .sourceMedia, replaceExisting: true)
            model.stageBatchInput([dstDir], slot: .targetMedia, replaceExisting: true)
            let enteredStage2Embedded = model.isBatchInQueueStage && model.batchSubtitleMode == .embedded
            model.stageBatchInput([subDir], slot: .externalSubtitles, replaceExisting: false)
            check(
                "AppModel Stage 2 Add External Subtitle Folder switches to External and pairs all 3 episodes",
                enteredStage2Embedded
                    && model.batchSubtitleMode == .external
                    && verifyThreeEpisodesPaired(in: model.batchJobs),
                detail: "jobs=\(model.batchJobs.map { "\($0.episodeBadge):\($0.externalSubtitleURL?.lastPathComponent ?? "nil")" }.joined(separator: ", "))"
            )

            // Flow C: Stage 2 direct drop of symlinked Subtitle Folder
            model.clearBatchQueue()
            model.batchSubtitleMode = .embedded
            model.stageBatchInput([srcDir], slot: .sourceMedia, replaceExisting: true)
            model.stageBatchInput([dstDir], slot: .targetMedia, replaceExisting: true)
            model.handleAutoBatchStage2Drop([symlinkSubDir])
            check(
                "AppModel Stage 2 drop of symlinked Subtitle Folder scans & pairs all 3 episodes",
                model.batchSubtitleMode == .external && verifyThreeEpisodesPaired(in: model.batchJobs),
                detail: "subs=\(model.stagedExternalSubtitles.count)"
            )
        } catch {
            check("AppModel real-folder Auto Batch integration setup", false, detail: error.localizedDescription)
        }

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

        // 7b. File Browser navigation history & type-locked selection checks
        var browserHistory = FileBrowserHistory()
        browserHistory.navigate(to: URL(fileURLWithPath: "/Media"))
        browserHistory.navigate(to: URL(fileURLWithPath: "/Media/Show"))
        let wentBack = browserHistory.goBack()?.path == "/Media"
        let wentForward = browserHistory.goForward()?.path == "/Media/Show"
        let wentUp = browserHistory.goUp()?.path == "/Media"
        check("File Browser Back/Forward/Up navigation works", wentBack && wentForward && wentUp)

        let selEntries = [
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep01.mkv"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep01.ass"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep02.mkv"), isDirectory: false),
        ]
        var selState = FileBrowserSelectionState()
        selState.plainClick(selEntries[0])
        selState.shiftClick(selEntries[2], visibleEntries: selEntries)
        check(
            "type-locked File Browser selection skips opposite file types",
            selState.selectedPaths == Set([selEntries[0].id, selEntries[2].id])
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
