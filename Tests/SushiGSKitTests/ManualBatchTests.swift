import Foundation
import Testing
@testable import SushiGSKit

@Suite("Manual Batch Column State, Row Pairing & Native File Browser")
struct ManualBatchTests {
    @Test("Pairs strictly by row index with zero filename or episode-number auto-matching")
    func strictIndexPairingZeroAutoMatch() {
        var columns = ManualBatchColumns(subtitleMode: .embedded)
        columns.insert(
            urls: [
                URL(fileURLWithPath: "/src/Episode_12.mkv"),
                URL(fileURLWithPath: "/src/Episode_01.mkv"),
            ],
            into: .sourceVideo,
            expandDirectories: false
        )
        columns.insert(
            urls: [
                URL(fileURLWithPath: "/dst/Completely_Different_A.mp4"),
                URL(fileURLWithPath: "/dst/Episode_12.mp4"),
            ],
            into: .targetVideo,
            expandDirectories: false
        )

        #expect(columns.rowCount == 2)
        #expect(columns.completeRowCount == 2)
        // Row 0 pairs Episode_12.mkv with Completely_Different_A.mp4 — never re-matched to Episode_12.mp4
        #expect(columns.row(at: 0).sourceURL?.lastPathComponent == "Episode_12.mkv")
        #expect(columns.row(at: 0).targetURL?.lastPathComponent == "Completely_Different_A.mp4")
        #expect(columns.row(at: 1).sourceURL?.lastPathComponent == "Episode_01.mkv")
        #expect(columns.row(at: 1).targetURL?.lastPathComponent == "Episode_12.mp4")
    }

    @Test("Independent column reordering updates row pairings without shifting other columns")
    func independentColumnReordering() {
        var columns = ManualBatchColumns(subtitleMode: .embedded)
        columns.insert(
            urls: [
                URL(fileURLWithPath: "/src/A.mkv"),
                URL(fileURLWithPath: "/src/B.mkv"),
                URL(fileURLWithPath: "/src/C.mkv"),
            ],
            into: .sourceVideo,
            expandDirectories: false
        )
        columns.insert(
            urls: [
                URL(fileURLWithPath: "/dst/1.mkv"),
                URL(fileURLWithPath: "/dst/2.mkv"),
                URL(fileURLWithPath: "/dst/3.mkv"),
            ],
            into: .targetVideo,
            expandDirectories: false
        )

        // Move Target item at index 2 ("3.mkv") to index 0
        columns.moveCell(in: .targetVideo, from: 2, to: 0)
        #expect(columns.targetVideos.compactMap(\.url?.lastPathComponent) == ["3.mkv", "1.mkv", "2.mkv"])
        // Source column untouched
        #expect(columns.sourceVideos.compactMap(\.url?.lastPathComponent) == ["A.mkv", "B.mkv", "C.mkv"])

        // MoveUp & MoveDown
        #expect(columns.moveUp(in: .targetVideo, at: 2) == true)
        #expect(columns.targetVideos.compactMap(\.url?.lastPathComponent) == ["3.mkv", "2.mkv", "1.mkv"])
        #expect(columns.moveDown(in: .targetVideo, at: 0) == true)
        #expect(columns.targetVideos.compactMap(\.url?.lastPathComponent) == ["2.mkv", "3.mkv", "1.mkv"])

        // Natural sort and reverse
        columns.sortNaturally(in: .targetVideo)
        #expect(columns.targetVideos.compactMap(\.url?.lastPathComponent) == ["1.mkv", "2.mkv", "3.mkv"])
        columns.reverse(in: .targetVideo)
        #expect(columns.targetVideos.compactMap(\.url?.lastPathComponent) == ["3.mkv", "2.mkv", "1.mkv"])
    }

    @Test("Blank-slot alignment shifts lower items down, marks row incomplete, and fills cleanly on drop")
    func blankSlotAlignmentAndReplacement() {
        var columns = ManualBatchColumns(subtitleMode: .external)
        columns.insert(
            urls: [
                URL(fileURLWithPath: "/src/Ep1.mkv"),
                URL(fileURLWithPath: "/src/Ep2.mkv"),
                URL(fileURLWithPath: "/src/Ep3.mkv"),
            ],
            into: .sourceVideo,
            expandDirectories: false
        )
        columns.insert(
            urls: [
                URL(fileURLWithPath: "/sub/Ep1.ass"),
                URL(fileURLWithPath: "/sub/Ep3.ass"),
            ],
            into: .sourceSubtitle,
            expandDirectories: false
        )
        columns.insert(
            urls: [
                URL(fileURLWithPath: "/dst/Ep1.mkv"),
                URL(fileURLWithPath: "/dst/Ep2.mkv"),
                URL(fileURLWithPath: "/dst/Ep3.mkv"),
            ],
            into: .targetVideo,
            expandDirectories: false
        )

        // Insert a blank slot at index 1 in Source Subtitles so Ep3.ass aligns with Ep3.mkv!
        let blankID = columns.insertBlankSlot(in: .sourceSubtitle, at: 1)
        #expect(columns.sourceSubtitles[1].id == blankID)
        #expect(columns.sourceSubtitles[1].isBlankSlot)
        #expect(columns.fileCount(in: .sourceSubtitle) == 2)
        #expect(columns.row(at: 0).isComplete == true)
        #expect(columns.row(at: 1).isComplete == false)
        #expect(columns.row(at: 2).isComplete == true)
        #expect(columns.row(at: 2).subtitleURL?.lastPathComponent == "Ep3.ass")
        #expect(columns.completeRowCount == 2)
        #expect(columns.incompleteRowCount == 1)

        // Dropping a file onto the blank slot fills it in place without pushing Ep3 down
        columns.insert(
            urls: [URL(fileURLWithPath: "/sub/Ep2.ass")],
            into: .sourceSubtitle,
            at: 1,
            expandDirectories: false
        )
        #expect(columns.sourceSubtitles.compactMap(\.url?.lastPathComponent) == ["Ep1.ass", "Ep2.ass", "Ep3.ass"])
        #expect(columns.completeRowCount == 3)
        #expect(columns.incompleteRowCount == 0)
    }

    @Test("Embedded vs External completeness and independent column clearing")
    func embeddedVsExternalCompletenessAndClearing() {
        var columns = ManualBatchColumns(subtitleMode: .embedded)
        columns.insert(
            urls: [URL(fileURLWithPath: "/src/01.mkv"), URL(fileURLWithPath: "/src/02.mkv")],
            into: .sourceVideo,
            expandDirectories: false
        )
        columns.insert(
            urls: [URL(fileURLWithPath: "/dst/01.mkv"), URL(fileURLWithPath: "/dst/02.mkv")],
            into: .targetVideo,
            expandDirectories: false
        )
        #expect(columns.activeColumns == [.sourceVideo, .targetVideo])
        #expect(columns.completeRowCount == 2)

        // Switching to External with no subtitles makes all rows incomplete
        columns.subtitleMode = .external
        #expect(columns.activeColumns == [.sourceVideo, .sourceSubtitle, .targetVideo])
        #expect(columns.completeRowCount == 0)
        #expect(columns.incompleteRowCount == 2)

        // Adding 1 subtitle makes row 0 complete, row 1 still incomplete
        columns.insert(urls: [URL(fileURLWithPath: "/sub/01.ass")], into: .sourceSubtitle, expandDirectories: false)
        #expect(columns.completeRowCount == 1)
        #expect(columns.incompleteRowCount == 1)

        // Clear only Source Subtitles — Source & Target remain intact
        columns.clear(column: .sourceSubtitle)
        #expect(columns.sourceSubtitles.isEmpty)
        #expect(columns.sourceVideos.count == 2)
        #expect(columns.targetVideos.count == 2)

        // Clear all empties every column
        columns.clearAll()
        #expect(columns.isEmpty)
        #expect(columns.rowCount == 0)
    }

    @Test("Folder drop expansion and FileBrowserScanner ignore dotfiles, filter extensions, and sort naturally")
    func folderDropExpansionAndFileBrowserScanner() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sushigs-manual-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let subFolder = tmp.appendingPathComponent("Season 1")
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)

        let files = [
            ".DS_Store",
            "Episode 10.mkv",
            "Episode 2.mkv",
            "Episode 1.mkv",
            "Episode 10.ass",
            "Episode 2.srt",
            "Episode 2.mkv.sushi.ass",
            "notes.txt",
        ]
        for name in files {
            FileManager.default.createFile(atPath: tmp.appendingPathComponent(name).path, contents: Data())
        }

        // Folder drop into Video column expands naturally sorted media only
        let expandedVideos = ManualBatchColumns.expandDroppedURLs([tmp], for: .sourceVideo)
        #expect(expandedVideos.map(\.lastPathComponent) == ["Episode 1.mkv", "Episode 2.mkv", "Episode 10.mkv"])

        // Folder drop into Subtitles column expands naturally sorted .ass/.srt/.ssa excluding .sushi. outputs
        let expandedSubs = ManualBatchColumns.expandDroppedURLs([tmp], for: .sourceSubtitle)
        #expect(expandedSubs.map(\.lastPathComponent) == ["Episode 2.srt", "Episode 10.ass"])

        // FileBrowserScanner lists directories first, ignores .DS_Store, respects filters and search
        let allEntries = FileBrowserScanner.listDirectory(tmp, filter: .all)
        #expect(!allEntries.contains(where: { $0.name == ".DS_Store" }))
        #expect(allEntries.first?.name == "Season 1")
        #expect(allEntries.first?.isDirectory == true)

        let videoEntries = FileBrowserScanner.listDirectory(tmp, filter: .video)
        #expect(videoEntries.filter { !$0.isDirectory }.map(\.name) == ["Episode 1.mkv", "Episode 2.mkv", "Episode 10.mkv"])

        let subEntries = FileBrowserScanner.listDirectory(tmp, filter: .subtitles)
        #expect(subEntries.filter { !$0.isDirectory }.map(\.name) == ["Episode 2.mkv.sushi.ass", "Episode 2.srt", "Episode 10.ass"])

        let searched = FileBrowserScanner.listDirectory(tmp, filter: .all, searchQuery: "episode 10")
        #expect(searched.map(\.name) == ["Episode 10.ass", "Episode 10.mkv"])
    }

    @Test("Type-locked Shift-click range selection skips opposite file types, folders, and unsupported files in both directions")
    func typeLockedShiftClickRangeSelection() {
        let entries = [
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Subfolder"), isDirectory: true),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep01.mkv"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep01.ass"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep02.mkv"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/notes.txt"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep02.srt"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep03.mkv"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep03.ssa"), isDirectory: false),
        ]

        // Media-first range select: Ep01.mkv -> Shift-click Ep03.ssa should select ONLY Ep01.mkv, Ep02.mkv, Ep03.mkv
        var sel = FileBrowserSelectionState()
        sel.plainClick(entries[1]) // Ep01.mkv (.media)
        #expect(sel.anchorKind == .media)
        sel.shiftClick(entries[7], visibleEntries: entries)
        let selectedMediaNames = entries.filter { sel.selectedPaths.contains($0.id) }.map(\.name)
        #expect(selectedMediaNames == ["Ep01.mkv", "Ep02.mkv", "Ep03.mkv"])

        // Subtitle-first range select: Ep01.ass -> Shift-click Ep03.mkv should select ONLY Ep01.ass, Ep02.srt
        sel.plainClick(entries[2]) // Ep01.ass (.subtitle)
        #expect(sel.anchorKind == .subtitle)
        sel.shiftClick(entries[6], visibleEntries: entries)
        let selectedSubNames = entries.filter { sel.selectedPaths.contains($0.id) }.map(\.name)
        #expect(selectedSubNames == ["Ep01.ass", "Ep02.srt"])
    }

    @Test("Type-locked Command-click skips opposite file types and clears anchor when selection becomes empty")
    func typeLockedCommandClickSelection() {
        let ep1Video = FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep01.mkv"), isDirectory: false)
        let ep2Video = FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep02.mkv"), isDirectory: false)
        let ep1Sub = FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep01.ass"), isDirectory: false)
        let ep2Sub = FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep02.srt"), isDirectory: false)
        let folder = FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Extras"), isDirectory: true)

        var sel = FileBrowserSelectionState()
        sel.plainClick(ep1Video)
        // Adding subtitle or folder while media-locked is ignored
        sel.commandClick(ep1Sub)
        sel.commandClick(folder)
        #expect(sel.selectedPaths == [ep1Video.id])

        // Adding another media file succeeds
        sel.commandClick(ep2Video)
        #expect(sel.selectedPaths == [ep1Video.id, ep2Video.id])
        #expect(sel.anchorKind == .media)

        // Deselecting all clears the anchor so subtitles can now be selected
        sel.commandClick(ep1Video)
        sel.commandClick(ep2Video)
        #expect(sel.isEmpty)
        #expect(sel.anchorPath == nil)
        #expect(sel.anchorKind == nil)

        // Subtitle-first lock ignores media files
        sel.commandClick(ep1Sub)
        #expect(sel.anchorKind == .subtitle)
        sel.commandClick(ep1Video)
        #expect(sel.selectedPaths == [ep1Sub.id])
        sel.commandClick(ep2Sub)
        #expect(sel.selectedPaths == [ep1Sub.id, ep2Sub.id])
    }

    @Test("Type-locked Command-A selects matching file kind and respects filter defaults")
    func typeLockedSelectAllAndDragCompatibility() {
        let entries = [
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Subfolder"), isDirectory: true),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep01.mkv"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep01.ass"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep02.mkv"), isDirectory: false),
            FileBrowserEntry(url: URL(fileURLWithPath: "/dir/Ep02.srt"), isDirectory: false),
        ]

        // Existing subtitle anchor -> Cmd+A selects only subtitles
        var sel = FileBrowserSelectionState()
        sel.plainClick(entries[2]) // Ep01.ass
        sel.selectAll(visibleEntries: entries, activeFilter: .all)
        #expect(entries.filter { sel.selectedPaths.contains($0.id) }.map(\.name) == ["Ep01.ass", "Ep02.srt"])
        #expect(sel.anchorKind == .subtitle)

        // Empty selection on All -> selects media if present
        sel.clear()
        sel.selectAll(visibleEntries: entries, activeFilter: .all)
        #expect(entries.filter { sel.selectedPaths.contains($0.id) }.map(\.name) == ["Ep01.mkv", "Ep02.mkv"])
        #expect(sel.anchorKind == .media)

        // Empty selection on All when only subtitles exist -> selects subtitles
        let subOnlyEntries = entries.filter { $0.kind != .media }
        sel.clear()
        sel.selectAll(visibleEntries: subOnlyEntries, activeFilter: .all)
        #expect(subOnlyEntries.filter { sel.selectedPaths.contains($0.id) }.map(\.name) == ["Ep01.ass", "Ep02.srt"])
        #expect(sel.anchorKind == .subtitle)

        // Column drag compatibility
        #expect(FileBrowserItemKind.media.acceptsColumn(.sourceVideo) == true)
        #expect(FileBrowserItemKind.media.acceptsColumn(.targetVideo) == true)
        #expect(FileBrowserItemKind.media.acceptsColumn(.sourceSubtitle) == false)
        #expect(FileBrowserItemKind.subtitle.acceptsColumn(.sourceSubtitle) == true)
        #expect(FileBrowserItemKind.subtitle.acceptsColumn(.sourceVideo) == false)
        #expect(FileBrowserItemKind.subtitle.acceptsColumn(.targetVideo) == false)
    }

    @Test("FileBrowserHistory tracks Back, Forward, and Parent-Up navigation accurately")
    func fileBrowserNavigationHistory() {
        var history = FileBrowserHistory()
        let dirA = URL(fileURLWithPath: "/Media")
        let dirB = URL(fileURLWithPath: "/Media/Show")
        let dirC = URL(fileURLWithPath: "/Media/Show/Season1")
        let dirD = URL(fileURLWithPath: "/Media/Show/Season2")

        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(!history.canGoUp)

        history.navigate(to: dirA)
        history.navigate(to: dirB)
        history.navigate(to: dirC)
        #expect(history.current?.path == dirC.path)
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.canGoUp)

        // Back C -> B -> A
        #expect(history.goBack()?.path == dirB.path)
        #expect(history.canGoForward)
        #expect(history.goBack()?.path == dirA.path)
        #expect(!history.canGoBack)

        // Forward A -> B, then navigating to D clears forward stack
        #expect(history.goForward()?.path == dirB.path)
        #expect(history.canGoForward)
        history.navigate(to: dirD)
        #expect(!history.canGoForward)
        #expect(history.current?.path == dirD.path)

        // Parent Up from /Media/Show/Season2 -> /Media/Show
        #expect(history.goUp()?.path == dirB.path)
        #expect(history.canGoBack)
        #expect(history.goBack()?.path == dirD.path)
    }
}
