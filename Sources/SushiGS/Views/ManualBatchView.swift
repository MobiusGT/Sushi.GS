import AppKit
import Observation
import SwiftUI
import SushiGSKit
import UniformTypeIdentifiers

// MARK: - Internal Drag Payload & Isolated Local Drag Coordinator

private nonisolated struct ManualDragTransfer: Codable, Sendable {
    var sushiManualTransfer: Bool = true
    var filePaths: [String]
    var itemKind: FileBrowserItemKind?
}

/// Lightweight local drag coordinator owned by `ManualBatchView` (never on `AppModel`).
/// Isolates ephemeral drag hover state so dragging over rows only updates the affected column's
/// 2 pt insertion-line overlay without re-rendering the File Browser, top navigation bar, or untouched columns.
@Observable
final class ManualDragCoordinator {
    // Active drag originating from the File Browser
    var browserDragKind: FileBrowserItemKind?
    @ObservationIgnored var browserDragURLs: [URL] = []

    // Active direct pointer reorder within a single pairing column (zero NSItemProvider overhead)
    var reorderColumn: ManualBatchColumnKind?
    var reorderCellIDs: Set<UUID> = []
    var reorderOriginIndex: Int?

    // Targeted drop slot — deduplicated so integer slot changes only redraw the insertion line
    var dropTargetColumn: ManualBatchColumnKind?
    var dropInsertIndex: Int?

    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?

    var isAnyDragActive: Bool {
        browserDragKind != nil || reorderColumn != nil
    }

    func isColumnIncompatible(_ column: ManualBatchColumnKind) -> Bool {
        if let kind = browserDragKind {
            return !kind.acceptsColumn(column)
        }
        if let activeReorder = reorderColumn {
            return activeReorder != column
        }
        return false
    }

    func isCellBeingReordered(column: ManualBatchColumnKind, cellID: UUID) -> Bool {
        reorderColumn == column && reorderCellIDs.contains(cellID)
    }

    func beginBrowserDrag(urls: [URL], kind: FileBrowserItemKind?) {
        cleanupTask?.cancel()
        browserDragURLs = urls
        browserDragKind = kind
        dropTargetColumn = nil
        dropInsertIndex = nil
        installDragEndMonitors()
    }

    func updateDropTarget(column: ManualBatchColumnKind?, index: Int?) {
        if dropTargetColumn != column {
            dropTargetColumn = column
        }
        if dropInsertIndex != index {
            dropInsertIndex = index
        }
    }

    func updatePointerReorder(
        column: ManualBatchColumnKind,
        cellIDs: Set<UUID>,
        originIndex: Int,
        locationY: CGFloat,
        columnCount: Int,
        rowHeight: CGFloat
    ) {
        if reorderColumn != column {
            reorderColumn = column
            installEscapeMonitorForReorder()
        }
        if reorderCellIDs != cellIDs {
            reorderCellIDs = cellIDs
        }
        if reorderOriginIndex != originIndex {
            reorderOriginIndex = originIndex
        }
        let rawSlot = Int((locationY / rowHeight).rounded())
        let clampedSlot = max(0, min(rawSlot, columnCount))
        updateDropTarget(column: column, index: clampedSlot)
    }

    func consumeBrowserDragURLs() -> [URL]? {
        guard !browserDragURLs.isEmpty else { return nil }
        let urls = browserDragURLs
        endAllDrags()
        return urls
    }

    func endAllDrags() {
        cleanupTask?.cancel()
        cleanupTask = nil
        removeDragEndMonitors()
        if browserDragKind != nil { browserDragKind = nil }
        if !browserDragURLs.isEmpty { browserDragURLs = [] }
        if reorderColumn != nil { reorderColumn = nil }
        if !reorderCellIDs.isEmpty { reorderCellIDs = [] }
        if reorderOriginIndex != nil { reorderOriginIndex = nil }
        if dropTargetColumn != nil { dropTargetColumn = nil }
        if dropInsertIndex != nil { dropInsertIndex = nil }
    }

    private func scheduleCleanupAfterPointerRelease() {
        cleanupTask?.cancel()
        cleanupTask = Task { @MainActor [weak self] in
            // Allow performDrop (if hovering a valid column) to run first before clearing state.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            if (NSEvent.pressedMouseButtons & 1) == 0 {
                self.endAllDrags()
            }
        }
    }

    private func installDragEndMonitors() {
        removeDragEndMonitors()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.browserDragKind != nil else { return }
                if event.type == .keyDown && event.keyCode == 53 {
                    self.endAllDrags()
                } else if event.type == .leftMouseUp {
                    self.scheduleCleanupAfterPointerRelease()
                } else if event.type == .mouseMoved && (NSEvent.pressedMouseButtons & 1) == 0 {
                    self.endAllDrags()
                }
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.browserDragKind != nil else { return }
                self.scheduleCleanupAfterPointerRelease()
            }
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.browserDragKind != nil else { return }
                if (NSEvent.pressedMouseButtons & 1) == 0 {
                    self.endAllDrags()
                }
            }
        }
    }

    private func installEscapeMonitorForReorder() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 {
                    self?.endAllDrags()
                }
            }
            return event
        }
    }

    func removeDragEndMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}

// MARK: - Manual Batch Workspace (Inverted-L File Browser + Synchronized Resizable Columns)

struct ManualBatchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    @AppStorage("manualBatch.browserWidth") private var storedBrowserWidth: Double = 224
    @AppStorage("manualBatch.embeddedSourceRatio") private var storedEmbeddedSourceRatio: Double = 0.50
    @AppStorage("manualBatch.externalSourceRatio") private var storedExternalSourceRatio: Double = 0.34
    @AppStorage("manualBatch.externalSubtitleRatio") private var storedExternalSubtitleRatio: Double = 0.32

    @State private var dragCoordinator = ManualDragCoordinator()
    @State private var showTrackRulesPopover = false
    @State private var isBrowserDropTargeted = false
    @State private var dragStartBrowserWidth: CGFloat?
    @State private var dragStartSourceRatio: Double?
    @State private var dragStartSubtitleRatio: Double?

    private let rowHeight: CGFloat = 32
    private let browserNavBarHeight: CGFloat = 40
    private let columnHeaderHeight: CGFloat = 48
    private let indexGutterWidth: CGFloat = 32
    private let statusColWidth: CGFloat = 88

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: Space.md) {
            if !model.dependencies.allRequiredReady {
                MissingDependenciesBanner(
                    missingCount: model.dependencies.missingRequiredDependencies.count,
                    isInstalling: model.dependencies.isBusy,
                    onInstall: { Task { await model.dependencies.installAllRequired(config: model.config) } },
                    onOpenDependencies: { model.sidebar = .dependencies }
                )
                .padding(.horizontal, Space.margin)
                .padding(.top, Space.md)
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                manualPrimaryHeaderBar
                    .gridProbe("manualHeader", area: "manual")

                manualSecondaryBar
                    .gridProbe("manualTools", area: "manual")

                InlineSyncOptionsStrip(includeHQToggle: true, framedAsCard: true)
                    .gridProbe("manualSyncOptions", area: "manual")
            }
            .padding(.horizontal, Space.margin)
            .padding(.top, model.dependencies.allRequiredReady ? Space.md : 0)

            VStack(spacing: 0) {
                Divider()

                // Inverted-L (Γ) Top Horizontal File Browser Navigation Bar
                ManualFileBrowserNavBar(
                    height: browserNavBarHeight,
                    isDropTargeted: $isBrowserDropTargeted
                )

                // Inverted-L (Γ) Body: Left Vertical File List + Right Nested Pairing Columns
                resizableColumnWorkspace
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

            if let selectedJob = selectedManualJob, shouldShowSelectedDetailStrip(selectedJob) {
                Divider()
                selectedRowDetailStrip(job: selectedJob)
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, Space.sm)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .gridArea("manual", inset: Space.margin)
        .onDisappear {
            dragCoordinator.endAllDrags()
        }
        .confirmationDialog(
            "Clear Manual Batch?",
            isPresented: $model.showClearManualBatchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                model.clearManualBatch()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All items in Source Video, Source Subtitles, and Target Video columns will be cleared. Your files on disk will not be modified.")
        }
    }

    // MARK: - Header Bars

    private var manualPrimaryHeaderBar: some View {
        let modeBinding = Binding<BatchSubtitleMode>(
            get: { model.manualColumns.subtitleMode },
            set: { model.setManualSubtitleMode($0) }
        )

        return HStack(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text("Subtitles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Subtitle Mode", selection: modeBinding) {
                    Text("Embedded")
                        .tag(BatchSubtitleMode.embedded)
                        .help(SushiHelpText.embeddedSubtitlesMode)
                    Text("External")
                        .tag(BatchSubtitleMode.external)
                        .help(SushiHelpText.externalSubtitlesMode)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 168)
                .hoverDescription(SushiHelpText.subtitleModeSwitch)
            }
            .hoverDescription(SushiHelpText.subtitleModeSwitch)

            readinessPill

            Spacer(minLength: Space.sm)

            if model.isRunning {
                Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                    model.togglePauseQueue()
                }
                .controlSize(.small)
                .fixedSize()
                .hoverDescription("Pause or resume Manual Batch after the current episode finishes (Option-Command-P)")

                Button(model.isCancelling ? "Cancelling…" : "Cancel", role: .destructive) {
                    model.cancelActiveJob()
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(model.isCancelling)
                .hoverDescription("Cancel the active episode and delete temporary and partial files (Command-Period)")
            } else {
                Button("Clear All") {
                    model.requestClearManualBatch()
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(model.manualColumns.isEmpty)
                .hoverDescription("Clear every pairing column in Manual Batch")

                Button {
                    model.startManualBatchQueue()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .disabled(!model.dependencies.allRequiredReady || !model.manualJobs.contains(where: \.hasPairedFiles))
                .hoverDescription("Start syncing complete Manual Batch pairs in row order (Command-R)")
            }
        }
    }

    @ViewBuilder
    private var readinessPill: some View {
        let total = model.manualColumns.rowCount
        let complete = model.manualColumns.completeRowCount
        let incomplete = model.manualColumns.incompleteRowCount

        if total > 0 {
            if incomplete == 0 {
                Label("\(complete) \(complete == 1 ? "Pair" : "Pairs") Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Surfaces.statusSuccess)
                    .lineLimit(1)
                    .hoverDescription("Every row has all required files assigned for strict row-by-row pairing")
            } else {
                Label("\(complete) Ready · \(incomplete) Incomplete", systemImage: "exclamationmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Surfaces.statusWarning)
                    .lineLimit(1)
                    .hoverDescription("Incomplete rows are missing a required file and will be safely skipped when starting")
            }
        }
    }

    private var manualSecondaryBar: some View {
        @Bindable var model = model
        let hasFlagged = model.manualJobs.contains(where: {
            $0.hasPairedFiles && ($0.status == .failed || $0.status == .warned || $0.status == .cancelled)
        })
        let hasMergeReady = model.manualJobs.contains(where: \.canMergeManually) && model.dependencies.isInstalled(.mkvmerge)

        return HStack(spacing: Space.sm) {
            Button("Track Rules…", systemImage: "slider.horizontal.3") {
                showTrackRulesPopover.toggle()
            }
            .controlSize(.small)
            .fixedSize()
            .popover(isPresented: $showTrackRulesPopover, arrowEdge: .bottom) {
                BatchTrackRulesPopover(
                    srcAudioRule: $model.manualSrcAudioRule,
                    dstAudioRule: $model.manualDstAudioRule,
                    subRule: $model.manualSubRule,
                    showSubtitleRule: model.manualColumns.subtitleMode == .embedded,
                    onApply: { model.applyManualTrackRulesToAll() }
                )
            }
            .hoverDescription("Configure Source Audio, Target Audio, and Embedded Subtitle track rules for Manual Batch")

            Menu {
                ForEach(model.presets) { preset in
                    Button(preset.name) { model.applyPreset(preset) }
                }
            } label: {
                Label("Presets", systemImage: "slider.horizontal.below.rectangle")
            }
            .controlSize(.small)
            .fixedSize()
            .hoverDescription("Apply a saved sync, audio encode, and MKV merge preset")

            Spacer(minLength: Space.sm)

            Button("Retry Flagged", systemImage: "arrow.counterclockwise") {
                model.retryFailedOrWarned()
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isRunning || !hasFlagged)
            .hoverDescription("Re-run failed, warned, or cancelled Manual Batch pairs (Shift-Command-R)")

            Button("Merge Ready", systemImage: "film.stack") {
                model.mergeCompletedJobs()
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isRunning || !hasMergeReady)
            .hoverDescription("Merge synced Manual Batch episodes into MKV files (Shift-Command-M)")
        }
    }

    // MARK: - Resizable Multi-Column Split Layout Nested Inside Inverted-L (Γ)

    private struct PairingColumnWidths {
        let sourceWidth: CGFloat
        let subtitleWidth: CGFloat
        let targetWidth: CGFloat
    }

    private var resizableColumnWorkspace: some View {
        let isExternal = model.manualColumns.subtitleMode == .external

        return GeometryReader { geo in
            let totalWidth = max(geo.size.width, 520)
            let totalHeight = max(geo.size.height, 160)
            let scrollViewportHeight = max(totalHeight - columnHeaderHeight - 2, 100)
            let minBrowser: CGFloat = 172
            let maxBrowser: CGFloat = min(420, totalWidth * 0.42)
            let browserWidth = min(max(CGFloat(storedBrowserWidth), minBrowser), maxBrowser)
            let pairingAreaWidth = max(totalWidth - browserWidth - 1, 320)
            let dividerCount: CGFloat = isExternal ? 2 : 1
            let dataColsWidth = max(pairingAreaWidth - indexGutterWidth - statusColWidth - dividerCount, 200)

            let columnWidths = computeColumnWidths(
                dataColsWidth: dataColsWidth,
                isExternal: isExternal
            )

            HStack(spacing: 0) {
                // Vertical stem of the inverted-L (Γ) File Browser (shares Surfaces.card fill with top nav bar)
                ManualFileBrowserListPane(
                    dragCoordinator: dragCoordinator,
                    isDropTargeted: $isBrowserDropTargeted,
                    onAddFilesToColumn: { urls, col in
                        model.manualInsert(urls: urls, into: col, at: nil, expandDirectories: true, undoManager: undoManager)
                    }
                )
                .frame(width: browserWidth, height: totalHeight, alignment: .topLeading)

                // Resizable Divider 0: File Browser vertical stem | Pairing Workspace
                ColumnResizeDivider(
                    height: totalHeight,
                    onDragChanged: { delta in
                        if dragStartBrowserWidth == nil {
                            dragStartBrowserWidth = browserWidth
                        }
                        let next = (dragStartBrowserWidth ?? browserWidth) + delta
                        storedBrowserWidth = Double(min(max(next, minBrowser), maxBrowser))
                    },
                    onDragEnded: {
                        dragStartBrowserWidth = nil
                    },
                    onDoubleClickReset: {
                        storedBrowserWidth = 224
                    }
                )

                // Right Side: Pairing Columns nested cleanly inside the Γ corner
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        // Crisp inner horizontal seam separating the Γ top nav bar from the pairing columns
                        Rectangle()
                            .fill(Surfaces.hairline)
                            .frame(width: pairingAreaWidth, height: 1)

                        pairingHeadersRow(columnWidths: columnWidths, isExternal: isExternal)
                            .frame(width: pairingAreaWidth, height: columnHeaderHeight)
                            .background(Surfaces.dropZone)

                        Divider()

                        pairingScrollBody(
                            columnWidths: columnWidths,
                            isExternal: isExternal,
                            viewportHeight: scrollViewportHeight
                        )
                        .frame(width: pairingAreaWidth, height: scrollViewportHeight)
                    }
                    .frame(width: pairingAreaWidth, height: totalHeight, alignment: .topLeading)

                    // Full-height interactive column resize dividers between pairing columns
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: indexGutterWidth + columnWidths.sourceWidth, height: totalHeight)
                            .allowsHitTesting(false)

                        ColumnResizeDivider(
                            height: totalHeight,
                            onDragChanged: { delta in
                                resizeFirstPairingBoundary(delta: delta, dataColsWidth: dataColsWidth, isExternal: isExternal, current: columnWidths)
                            },
                            onDragEnded: {
                                dragStartSourceRatio = nil
                                dragStartSubtitleRatio = nil
                            },
                            onDoubleClickReset: {
                                if isExternal {
                                    storedExternalSourceRatio = 0.34
                                    storedExternalSubtitleRatio = 0.32
                                } else {
                                    storedEmbeddedSourceRatio = 0.50
                                }
                            }
                        )

                        if isExternal {
                            Color.clear
                                .frame(width: columnWidths.subtitleWidth, height: totalHeight)
                                .allowsHitTesting(false)

                            ColumnResizeDivider(
                                height: totalHeight,
                                onDragChanged: { delta in
                                    resizeSecondPairingBoundary(delta: delta, dataColsWidth: dataColsWidth, current: columnWidths)
                                },
                                onDragEnded: {
                                    dragStartSubtitleRatio = nil
                                },
                                onDoubleClickReset: {
                                    storedExternalSourceRatio = 0.34
                                    storedExternalSubtitleRatio = 0.32
                                }
                            )
                        }

                        Spacer(minLength: 0)
                            .allowsHitTesting(false)
                    }
                    .frame(width: pairingAreaWidth, height: totalHeight, alignment: .topLeading)
                }
                .frame(width: pairingAreaWidth, height: totalHeight, alignment: .topLeading)
                .onDeleteCommand {
                    model.manualRemoveSelectedCells(undoManager: undoManager)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "manualBatchColumns")
        }
    }

    private func computeColumnWidths(dataColsWidth: CGFloat, isExternal: Bool) -> PairingColumnWidths {
        if isExternal {
            let minCol: CGFloat = 104
            let maxSrc = max(minCol, dataColsWidth - 2 * minCol)
            let srcW = min(max(dataColsWidth * CGFloat(storedExternalSourceRatio), minCol), maxSrc)
            let maxSub = max(minCol, dataColsWidth - srcW - minCol)
            let subW = min(max(dataColsWidth * CGFloat(storedExternalSubtitleRatio), minCol), maxSub)
            let dstW = max(dataColsWidth - srcW - subW, minCol)
            return PairingColumnWidths(sourceWidth: srcW, subtitleWidth: subW, targetWidth: dstW)
        } else {
            let minCol: CGFloat = 120
            let maxSrc = max(minCol, dataColsWidth - minCol)
            let srcW = min(max(dataColsWidth * CGFloat(storedEmbeddedSourceRatio), minCol), maxSrc)
            let dstW = max(dataColsWidth - srcW, minCol)
            return PairingColumnWidths(sourceWidth: srcW, subtitleWidth: 0, targetWidth: dstW)
        }
    }

    // MARK: - Pairing Column Headers

    private func pairingHeadersRow(
        columnWidths: PairingColumnWidths,
        isExternal: Bool
    ) -> some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: indexGutterWidth, alignment: .center)
                .hoverDescription("Row pair number — files on the same row are paired directly")

            pairingColumnHeader(column: .sourceVideo)
                .frame(width: columnWidths.sourceWidth, height: columnHeaderHeight)
                .overlay {
                    ManualColumnHeaderDimOverlay(column: .sourceVideo, coordinator: dragCoordinator)
                }

            Rectangle()
                .fill(Surfaces.hairline)
                .frame(width: 1, height: columnHeaderHeight)

            if isExternal {
                pairingColumnHeader(column: .sourceSubtitle)
                    .frame(width: columnWidths.subtitleWidth, height: columnHeaderHeight)
                    .overlay {
                        ManualColumnHeaderDimOverlay(column: .sourceSubtitle, coordinator: dragCoordinator)
                    }

                Rectangle()
                    .fill(Surfaces.hairline)
                    .frame(width: 1, height: columnHeaderHeight)
            }

            pairingColumnHeader(column: .targetVideo)
                .frame(width: columnWidths.targetWidth, height: columnHeaderHeight)
                .overlay {
                    ManualColumnHeaderDimOverlay(column: .targetVideo, coordinator: dragCoordinator)
                }

            Text("Status")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: statusColWidth, alignment: .center)
                .hoverDescription("Sync readiness and run status for each paired row")
        }
    }

    private func pairingColumnHeader(column: ManualBatchColumnKind) -> some View {
        let count = model.manualColumns.fileCount(in: column)
        let hasItems = !model.manualColumns.cells(in: column).isEmpty

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.xs) {
                Text(column.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Space.xs)
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(count > 0 ? .primary : .secondary)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, 1)
                    .background(Surfaces.cardHover, in: Capsule())
                    .hoverDescription("\(count) \(count == 1 ? "file" : "files") in \(column.title)")
            }

            HStack(spacing: Space.sm) {
                Button {
                    model.manualPickFiles(for: column, undoManager: undoManager)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isRunning)
                .hoverDescription("Add files or folders to \(column.title)")

                Button {
                    model.manualSortColumn(column, undoManager: undoManager)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption2)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasItems ? .secondary : .tertiary)
                .disabled(model.isRunning || count < 2)
                .hoverDescription("Sort \(column.title) A–Z in natural Finder order")

                Button {
                    model.manualReverseColumn(column, undoManager: undoManager)
                } label: {
                    Image(systemName: "arrow.uturn.down")
                        .font(.caption2)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasItems ? .secondary : .tertiary)
                .disabled(model.isRunning || model.manualColumns.cells(in: column).count < 2)
                .hoverDescription("Reverse the item order in \(column.title)")

                Spacer(minLength: 0)

                Button {
                    model.manualClearColumn(column, undoManager: undoManager)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasItems ? .secondary : .tertiary)
                .disabled(model.isRunning || !hasItems)
                .hoverDescription("Clear all items from \(column.title)")
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
    }

    private func resizeFirstPairingBoundary(
        delta: CGFloat,
        dataColsWidth: CGFloat,
        isExternal: Bool,
        current: PairingColumnWidths
    ) {
        guard dataColsWidth > 0 else { return }
        if isExternal {
            if dragStartSourceRatio == nil {
                dragStartSourceRatio = Double(current.sourceWidth / dataColsWidth)
                dragStartSubtitleRatio = Double(current.subtitleWidth / dataColsWidth)
            }
            let baseSrc = dragStartSourceRatio ?? storedExternalSourceRatio
            let baseSub = dragStartSubtitleRatio ?? storedExternalSubtitleRatio
            let minRatio = Double(104 / dataColsWidth)
            let combined = baseSrc + baseSub
            let nextSrc = min(max(baseSrc + Double(delta / dataColsWidth), minRatio), combined - minRatio)
            storedExternalSourceRatio = nextSrc
            storedExternalSubtitleRatio = max(minRatio, combined - nextSrc)
        } else {
            if dragStartSourceRatio == nil {
                dragStartSourceRatio = Double(current.sourceWidth / dataColsWidth)
            }
            let baseSrc = dragStartSourceRatio ?? storedEmbeddedSourceRatio
            let minRatio = Double(120 / dataColsWidth)
            storedEmbeddedSourceRatio = min(max(baseSrc + Double(delta / dataColsWidth), minRatio), 1.0 - minRatio)
        }
    }

    private func resizeSecondPairingBoundary(
        delta: CGFloat,
        dataColsWidth: CGFloat,
        current: PairingColumnWidths
    ) {
        guard dataColsWidth > 0 else { return }
        if dragStartSubtitleRatio == nil {
            dragStartSubtitleRatio = Double(current.subtitleWidth / dataColsWidth)
        }
        let baseSub = dragStartSubtitleRatio ?? storedExternalSubtitleRatio
        let srcRatio = Double(current.sourceWidth / dataColsWidth)
        let minRatio = Double(104 / dataColsWidth)
        let maxSub = max(minRatio, 1.0 - srcRatio - minRatio)
        storedExternalSubtitleRatio = min(max(baseSub + Double(delta / dataColsWidth), minRatio), maxSub)
    }

    // MARK: - Synchronized Scrollable Pairing Rows + Column-Level Drop Overlays

    private func pairingScrollBody(
        columnWidths: PairingColumnWidths,
        isExternal: Bool,
        viewportHeight: CGFloat
    ) -> some View {
        let rows = model.manualColumns.rows
        let contentHeight = rows.isEmpty
            ? max(viewportHeight, 160)
            : max(viewportHeight, CGFloat(rows.count) * rowHeight + 64)
        let tailHeight = max(64, contentHeight - CGFloat(rows.count) * rowHeight)

        return ScrollView {
            ZStack(alignment: .topLeading) {
                // Layer 1 (Bottom): Single column-level DropDelegate targets (2 or 3 total — never per-cell!)
                // AppKit routes drag sessions through non-drop rows above directly to these column targets.
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: indexGutterWidth, height: contentHeight)

                    ManualColumnDropHitTarget(
                        column: .sourceVideo,
                        width: columnWidths.sourceWidth,
                        height: contentHeight,
                        rowHeight: rowHeight,
                        itemCount: model.manualColumns.sourceVideos.count,
                        coordinator: dragCoordinator,
                        onCommitDrop: { urls, insertIdx, expand in
                            model.manualInsert(urls: urls, into: .sourceVideo, at: insertIdx, expandDirectories: expand, undoManager: undoManager)
                        }
                    )

                    Color.clear
                        .frame(width: 1, height: contentHeight)

                    if isExternal {
                        ManualColumnDropHitTarget(
                            column: .sourceSubtitle,
                            width: columnWidths.subtitleWidth,
                            height: contentHeight,
                            rowHeight: rowHeight,
                            itemCount: model.manualColumns.sourceSubtitles.count,
                            coordinator: dragCoordinator,
                            onCommitDrop: { urls, insertIdx, expand in
                                model.manualInsert(urls: urls, into: .sourceSubtitle, at: insertIdx, expandDirectories: expand, undoManager: undoManager)
                            }
                        )

                        Color.clear
                            .frame(width: 1, height: contentHeight)
                    }

                    ManualColumnDropHitTarget(
                        column: .targetVideo,
                        width: columnWidths.targetWidth,
                        height: contentHeight,
                        rowHeight: rowHeight,
                        itemCount: model.manualColumns.targetVideos.count,
                        coordinator: dragCoordinator,
                        onCommitDrop: { urls, insertIdx, expand in
                            model.manualInsert(urls: urls, into: .targetVideo, at: insertIdx, expandDirectories: expand, undoManager: undoManager)
                        }
                    )

                    Color.clear
                        .frame(width: statusColWidth, height: contentHeight)
                }
                .frame(height: contentHeight)

                // Layer 2 (Middle): Interactive pairing rows + direct pointer intra-column reordering
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        emptyColumnsCanvas(
                            columnWidths: columnWidths,
                            isExternal: isExternal,
                            canvasHeight: contentHeight
                        )
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(rows, id: \.index) { row in
                                ManualPairedRowView(
                                    row: row,
                                    job: model.manualJobs.indices.contains(row.index) ? model.manualJobs[row.index] : nil,
                                    sourceWidth: columnWidths.sourceWidth,
                                    subtitleWidth: columnWidths.subtitleWidth,
                                    targetWidth: columnWidths.targetWidth,
                                    isExternal: isExternal,
                                    indexGutterWidth: indexGutterWidth,
                                    statusColWidth: statusColWidth,
                                    rowHeight: rowHeight,
                                    dragCoordinator: dragCoordinator,
                                    onSelectCell: { col, cell in
                                        handleCellClick(column: col, rowIndex: row.index, cell: cell)
                                    },
                                    onSelectRow: {
                                        model.selectedManualRowIndex = row.index
                                        model.selectedManualColumn = nil
                                        model.selectedManualCellIDs.removeAll()
                                    },
                                    onPointerReorderChanged: { col, cell, y in
                                        handlePointerReorderChanged(column: col, rowIndex: row.index, cell: cell, locationY: y)
                                    },
                                    onPointerReorderEnded: { col in
                                        handlePointerReorderEnded(column: col)
                                    }
                                )
                            }
                        }

                        // Continuous column hairlines below rows so the workspace feels solid
                        HStack(spacing: 0) {
                            Color.clear.frame(width: indexGutterWidth + columnWidths.sourceWidth, height: tailHeight)
                            Rectangle().fill(Surfaces.hairline).frame(width: 1, height: tailHeight)
                            if isExternal {
                                Color.clear.frame(width: columnWidths.subtitleWidth, height: tailHeight)
                                Rectangle().fill(Surfaces.hairline).frame(width: 1, height: tailHeight)
                            }
                            Color.clear.frame(width: columnWidths.targetWidth + statusColWidth, height: tailHeight)
                        }
                        .frame(height: tailHeight)
                        .allowsHitTesting(false)
                    }
                }

                // Layer 3 (Top, non-hit-testing): Isolated visual feedback (incompatible column dim + 2 pt insertion line)
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: indexGutterWidth, height: contentHeight)

                    ManualColumnVisualOverlay(
                        column: .sourceVideo,
                        width: columnWidths.sourceWidth,
                        height: contentHeight,
                        rowHeight: rowHeight,
                        coordinator: dragCoordinator
                    )

                    Color.clear
                        .frame(width: 1, height: contentHeight)

                    if isExternal {
                        ManualColumnVisualOverlay(
                            column: .sourceSubtitle,
                            width: columnWidths.subtitleWidth,
                            height: contentHeight,
                            rowHeight: rowHeight,
                            coordinator: dragCoordinator
                        )

                        Color.clear
                            .frame(width: 1, height: contentHeight)
                    }

                    ManualColumnVisualOverlay(
                        column: .targetVideo,
                        width: columnWidths.targetWidth,
                        height: contentHeight,
                        rowHeight: rowHeight,
                        coordinator: dragCoordinator
                    )

                    Color.clear
                        .frame(width: statusColWidth, height: contentHeight)
                }
                .frame(height: contentHeight)
                .allowsHitTesting(false)
            }
            .coordinateSpace(name: "pairingRowsScroll")
        }
    }

    private func emptyColumnsCanvas(
        columnWidths: PairingColumnWidths,
        isExternal: Bool,
        canvasHeight: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: indexGutterWidth, height: canvasHeight)

            ManualEmptyColumnPlaceholder(
                column: .sourceVideo,
                prompt: "Drop source videos or folders",
                onAdd: { model.manualPickFiles(for: .sourceVideo, undoManager: undoManager) }
            )
            .frame(width: columnWidths.sourceWidth, height: canvasHeight)

            Rectangle()
                .fill(Surfaces.hairline)
                .frame(width: 1, height: canvasHeight)

            if isExternal {
                ManualEmptyColumnPlaceholder(
                    column: .sourceSubtitle,
                    prompt: "Drop .ass, .srt, .ssa files or folders",
                    onAdd: { model.manualPickFiles(for: .sourceSubtitle, undoManager: undoManager) }
                )
                .frame(width: columnWidths.subtitleWidth, height: canvasHeight)

                Rectangle()
                    .fill(Surfaces.hairline)
                    .frame(width: 1, height: canvasHeight)
            }

            ManualEmptyColumnPlaceholder(
                column: .targetVideo,
                prompt: "Drop target videos or folders",
                onAdd: { model.manualPickFiles(for: .targetVideo, undoManager: undoManager) }
            )
            .frame(width: columnWidths.targetWidth, height: canvasHeight)

            Color.clear
                .frame(width: statusColWidth, height: canvasHeight)
        }
        .frame(height: canvasHeight)
    }

    // MARK: - Selected Row Detail Strip (Warnings, Errors, Outputs)

    private var selectedManualJob: EpisodeJob? {
        guard let idx = model.selectedManualRowIndex, model.manualJobs.indices.contains(idx) else { return nil }
        return model.manualJobs[idx]
    }

    private func shouldShowSelectedDetailStrip(_ job: EpisodeJob) -> Bool {
        !job.warnings.isEmpty
            || job.errorMessage != nil
            || job.status == .running
            || !job.syncedFiles.isEmpty
            || job.mergedFilepath != nil
    }

    private func selectedRowDetailStrip(job: EpisodeJob) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !job.warnings.isEmpty {
                WarningBannerView(job: job) { warning in
                    model.jumpToWarning(warning, in: job)
                }
            }

            if let error = job.errorMessage {
                ErrorBannerView(message: error) {
                    model.showInspector = true
                    model.logScope = .selectedJob
                }
            }

            if job.status == .running {
                HStack(spacing: Space.sm) {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                    Text(job.stageDetail.isEmpty ? "Syncing \(job.episodeBadge)…" : job.stageDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !job.syncedFiles.isEmpty || job.mergedFilepath != nil {
                HStack(spacing: Space.sm) {
                    Text("Pair \(job.episodeBadge) Outputs")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let sub = job.syncedFiles.first {
                        Button("Reveal Synced Subtitle", systemImage: "captions.bubble") {
                            model.revealInFinder(sub)
                        }
                        .controlSize(.small)
                        .hoverDescription("Reveal the synced subtitle output file in Finder")
                    }
                    if let mkv = job.mergedFilepath {
                        Button("Reveal Merged MKV", systemImage: "film.stack") {
                            model.revealInFinder(mkv)
                        }
                        .controlSize(.small)
                        .hoverDescription("Reveal the merged MKV output file in Finder")
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Cell Selection & Direct Pointer Intra-Column Reorder

    private func handleCellClick(column: ManualBatchColumnKind, rowIndex: Int, cell: ManualBatchCell?) {
        model.selectedManualRowIndex = rowIndex
        guard let cell else {
            model.selectedManualColumn = column
            model.selectedManualCellIDs.removeAll()
            return
        }

        let flags = NSEvent.modifierFlags
        let cells = model.manualColumns.cells(in: column)

        if flags.contains(.command), model.selectedManualColumn == column {
            if model.selectedManualCellIDs.contains(cell.id) {
                model.selectedManualCellIDs.remove(cell.id)
            } else {
                model.selectedManualCellIDs.insert(cell.id)
            }
        } else if flags.contains(.shift),
                  model.selectedManualColumn == column,
                  let firstSelectedIdx = cells.firstIndex(where: { model.selectedManualCellIDs.contains($0.id) }) {
            let range = min(firstSelectedIdx, rowIndex)...max(firstSelectedIdx, rowIndex)
            model.selectedManualCellIDs = Set(range.map { cells[$0].id })
        } else {
            model.selectedManualColumn = column
            model.selectedManualCellIDs = [cell.id]
        }
    }

    private func handlePointerReorderChanged(
        column: ManualBatchColumnKind,
        rowIndex: Int,
        cell: ManualBatchCell,
        locationY: CGFloat
    ) {
        guard !model.isRunning else { return }
        let ids: Set<UUID>
        if model.selectedManualColumn == column, model.selectedManualCellIDs.contains(cell.id) {
            ids = model.selectedManualCellIDs
        } else {
            ids = [cell.id]
        }
        let colCount = model.manualColumns.cells(in: column).count
        dragCoordinator.updatePointerReorder(
            column: column,
            cellIDs: ids,
            originIndex: rowIndex,
            locationY: locationY,
            columnCount: colCount,
            rowHeight: rowHeight
        )
    }

    private func handlePointerReorderEnded(column: ManualBatchColumnKind) {
        guard dragCoordinator.reorderColumn == column else {
            dragCoordinator.endAllDrags()
            return
        }
        let ids = dragCoordinator.reorderCellIDs
        let targetSlot = dragCoordinator.dropInsertIndex
        let origin = dragCoordinator.reorderOriginIndex
        dragCoordinator.endAllDrags()

        guard !ids.isEmpty, let dest = targetSlot else { return }
        if ids.count == 1, let origin, (dest == origin || dest == origin + 1) {
            return
        }
        model.manualMoveCells(in: column, ids: ids, to: dest, undoManager: undoManager)
    }
}

// MARK: - Inverted-L (Γ) Top Horizontal File Browser Navigation Bar

private struct ManualFileBrowserNavBar: View {
    @Environment(AppModel.self) private var model
    let height: CGFloat
    @Binding var isDropTargeted: Bool

    var body: some View {
        @Bindable var model = model

        HStack(spacing: Space.sm) {
            // Back / Forward / Parent Up navigation cluster
            HStack(spacing: Space.xs) {
                Button {
                    model.navigateManualBrowserBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.callout.weight(.medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.manualBrowserHistory.canGoBack ? .primary : .tertiary)
                .disabled(!model.manualBrowserHistory.canGoBack)
                .hoverDescription("Go back to the previous folder")

                Button {
                    model.navigateManualBrowserForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.manualBrowserHistory.canGoForward ? .primary : .tertiary)
                .disabled(!model.manualBrowserHistory.canGoForward)
                .hoverDescription("Go forward to the next folder")

                Button {
                    model.navigateManualBrowserUp()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.callout.weight(.medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.manualBrowserHistory.canGoUp ? .primary : .tertiary)
                .disabled(!model.manualBrowserHistory.canGoUp)
                .hoverDescription("Open the parent folder")
            }

            Rectangle()
                .fill(Surfaces.hairline)
                .frame(width: 1, height: 16)

            // Wide clickable Breadcrumb Path
            breadcrumbPathView
                .frame(maxWidth: .infinity, alignment: .leading)

            // Choose Folder & Refresh
            Button("Choose…", systemImage: "folder.badge.plus") {
                model.chooseManualBrowserFolder()
            }
            .controlSize(.small)
            .fixedSize()
            .hoverDescription("Choose a folder to open in the File Browser")

            Button {
                model.refreshManualBrowser()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.callout)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.manualBrowserRootURL == nil ? .tertiary : .secondary)
            .disabled(model.manualBrowserRootURL == nil)
            .hoverDescription("Refresh the current folder listing")

            // Compact Search box
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter files…", text: $model.manualBrowserSearch)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !model.manualBrowserSearch.isEmpty {
                    Button {
                        model.manualBrowserSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .hoverDescription("Clear file filter text")
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .frame(width: 144)
            .background(.background, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                    .strokeBorder(Surfaces.hairline, lineWidth: 1)
            )
            .hoverDescription("Filter visible files in the File Browser by name")

            // All / Video / Subtitles filter pills
            HStack(spacing: Space.xs) {
                ForEach(FileBrowserFilter.allCases) { filter in
                    let selected = model.manualBrowserFilter == filter
                    Button(filter.displayName) {
                        model.manualBrowserFilter = filter
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.onAccent : .primary)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .background(selected ? Palette.accent : Surfaces.cardHover, in: Capsule())
                    .hoverDescription(filterHelpText(for: filter))
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, Space.md)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(isDropTargeted ? Palette.accent.opacity(0.10) : Surfaces.card)
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .strokeBorder(Palette.accent, lineWidth: 2)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            let onRoot: @MainActor (URL) -> Void = { droppedURL in
                model.setManualBrowserRoot(droppedURL)
            }
            return DroppedFileURLLoader.load(from: providers) { urls in
                guard let first = urls.first else { return }
                onRoot(first)
            }
        }
    }

    private func filterHelpText(for filter: FileBrowserFilter) -> String {
        switch filter {
        case .all: "Show all files and folders in the File Browser"
        case .video: "Show only supported video and audio media files"
        case .subtitles: "Show only .ass, .srt, and .ssa subtitle files"
        }
    }

    @ViewBuilder
    private var breadcrumbPathView: some View {
        if let root = model.manualBrowserRootURL {
            let segments = breadcrumbSegments(for: root)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.accentText)

                    ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(seg.name) {
                            model.setManualBrowserRoot(seg.url)
                        }
                        .buttonStyle(.plain)
                        .font(.callout.weight(idx == segments.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == segments.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                        .hoverDescription("Open \(seg.url.path)")
                    }
                }
            }
        } else {
            HStack(spacing: Space.xs) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Drop a folder here or click Choose… to browse files")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func breadcrumbSegments(for url: URL) -> [(name: String, url: URL)] {
        var list: [(String, URL)] = []
        var cursor = url.standardizedFileURL
        for _ in 0..<6 {
            let name = cursor.lastPathComponent
            if name == "/" || name.isEmpty {
                if list.isEmpty {
                    list.append(("/", cursor))
                }
                break
            }
            list.append((name, cursor))
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return list.reversed()
    }
}

// MARK: - Inverted-L (Γ) Left Vertical File List (Type-Locked Multi-Selection)

private struct ManualFileBrowserListPane: View {
    @Environment(AppModel.self) private var model
    let dragCoordinator: ManualDragCoordinator
    @Binding var isDropTargeted: Bool
    let onAddFilesToColumn: ([URL], ManualBatchColumnKind) -> Void

    private struct FlattenedNode: Identifiable {
        let entry: FileBrowserEntry
        let depth: Int
        var id: String { entry.id }
    }

    var body: some View {
        let visibleNodes = flattenedVisibleNodes()
        let visibleEntries = visibleNodes.map(\.entry)

        Group {
            if model.manualBrowserRootURL == nil {
                VStack(spacing: Space.sm) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Drop a folder here or choose one above")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Choose Folder…") {
                        model.chooseManualBrowserFolder()
                    }
                    .controlSize(.small)
                    .hoverDescription("Choose a folder to browse in Manual Batch")
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleNodes.isEmpty {
                VStack(spacing: Space.xs) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(model.manualBrowserSearch.isEmpty ? "No matching files" : "No results for \"\(model.manualBrowserSearch)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleNodes) { node in
                            browserRow(node: node, visibleEntries: visibleEntries)
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onKeyPress(characters: CharacterSet(charactersIn: "aA"), phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.manualBrowserSelection.selectAll(
                        visibleEntries: visibleEntries,
                        activeFilter: model.manualBrowserFilter
                    )
                    return .handled
                }
            }
        }
        // Shares Surfaces.card tint seamlessly with the top navigation bar to form the Γ frame
        .background(isDropTargeted ? Palette.accent.opacity(0.10) : Surfaces.card)
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .strokeBorder(Palette.accent, lineWidth: 2)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            let onRoot: @MainActor (URL) -> Void = { droppedURL in
                model.setManualBrowserRoot(droppedURL)
            }
            return DroppedFileURLLoader.load(from: providers) { urls in
                guard let first = urls.first else { return }
                onRoot(first)
            }
        }
    }

    private func flattenedVisibleNodes() -> [FlattenedNode] {
        guard let root = model.manualBrowserRootURL else { return [] }
        var result: [FlattenedNode] = []

        func walk(_ dirURL: URL, depth: Int) {
            let children = model.manualBrowserChildren(of: dirURL)
            for entry in children {
                result.append(FlattenedNode(entry: entry, depth: depth))
                if entry.isDirectory && model.manualBrowserExpandedPaths.contains(entry.id) && depth < 6 {
                    walk(entry.url, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)
        return result
    }

    private func browserRow(node: FlattenedNode, visibleEntries: [FileBrowserEntry]) -> some View {
        let entry = node.entry
        let isSelected = model.manualBrowserSelection.selectedPaths.contains(entry.id)
        let isExpanded = model.manualBrowserExpandedPaths.contains(entry.id)
        let indent = CGFloat(node.depth) * Space.md

        return HStack(spacing: Space.xs) {
            if entry.isDirectory {
                Button {
                    model.toggleManualBrowserExpanded(entry.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.secondary))
                        .frame(width: 12, height: 16)
                }
                .buttonStyle(.plain)
                .hoverDescription(isExpanded ? "Collapse folder" : "Expand folder")
            } else {
                Color.clear.frame(width: 12, height: 16)
            }

            Image(systemName: entry.symbolName)
                .font(.caption)
                .foregroundStyle(iconColor(for: entry, isSelected: isSelected))
                .frame(width: 16)

            Text(entry.name)
                .font(.callout)
                .foregroundStyle(isSelected ? Palette.onAccent : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Space.xs)

            if let hint = entry.subtleDetailHint {
                Text(hint)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(Palette.onAccent.opacity(0.85)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.leading, Space.xs + indent)
        .padding(.trailing, Space.sm)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.accent : Color.clear, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        .padding(.horizontal, Space.xs)
        .contentShape(Rectangle())
        .help(entry.name)
        .onTapGesture(count: 2) {
            if entry.isDirectory {
                model.setManualBrowserRoot(entry.url)
            }
        }
        .onTapGesture(count: 1) {
            handleBrowserSelection(entry: entry, visibleEntries: visibleEntries)
        }
        .onDrag {
            makeBrowserDragProvider(for: entry, visibleEntries: visibleEntries)
        } preview: {
            let payload = model.manualBrowserSelection.dragPayload(for: entry, visibleEntries: visibleEntries)
            DragBadgePreview(count: payload.urls.count, title: entry.name)
        }
        .contextMenu {
            let payload = model.manualBrowserSelection.dragPayload(for: entry, visibleEntries: visibleEntries)
            let urls = payload.urls
            let suffix = urls.count > 1 ? " (\(urls.count))" : ""

            if payload.kind == nil || payload.kind == .media || entry.isDirectory {
                Button("Add to Source Video\(suffix)") {
                    onAddFilesToColumn(urls, .sourceVideo)
                }
                .disabled(model.isRunning)
            }

            if payload.kind == nil || payload.kind == .subtitle || entry.isDirectory {
                Button("Add to Source Subtitles\(suffix)") {
                    onAddFilesToColumn(urls, .sourceSubtitle)
                }
                .disabled(model.isRunning)
            }

            if payload.kind == nil || payload.kind == .media || entry.isDirectory {
                Button("Add to Target Video\(suffix)") {
                    onAddFilesToColumn(urls, .targetVideo)
                }
                .disabled(model.isRunning)
            }

            Divider()

            if entry.isDirectory {
                Button("Open Folder") {
                    model.setManualBrowserRoot(entry.url)
                }
            }

            Button("Select All Matching Files") {
                model.manualBrowserSelection.selectAll(
                    visibleEntries: visibleEntries,
                    activeFilter: model.manualBrowserFilter
                )
            }

            Button("Reveal in Finder") {
                model.revealInFinder(entry.url.path)
            }
        }
    }

    private func iconColor(for entry: FileBrowserEntry, isSelected: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Palette.onAccent) }
        switch entry.kind {
        case .folder: return AnyShapeStyle(Palette.accentText)
        case .subtitle: return AnyShapeStyle(Surfaces.statusRunning)
        case .media: return AnyShapeStyle(.secondary)
        case .other: return AnyShapeStyle(.tertiary)
        }
    }

    private func handleBrowserSelection(entry: FileBrowserEntry, visibleEntries: [FileBrowserEntry]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            model.manualBrowserSelection.shiftClick(entry, visibleEntries: visibleEntries)
        } else if flags.contains(.command) {
            model.manualBrowserSelection.commandClick(entry)
        } else {
            model.manualBrowserSelection.plainClick(entry)
        }
    }

    private func makeBrowserDragProvider(for entry: FileBrowserEntry, visibleEntries: [FileBrowserEntry]) -> NSItemProvider {
        let payload = model.manualBrowserSelection.dragPayload(for: entry, visibleEntries: visibleEntries)
        dragCoordinator.beginBrowserDrag(urls: payload.urls, kind: payload.kind)

        let transfer = ManualDragTransfer(
            filePaths: payload.urls.map(\.path),
            itemKind: payload.kind
        )
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(transfer) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.json.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}

// MARK: - Paired Row View (Isolated Per-Row Hover State)

private struct ManualPairedRowView: View {
    @Environment(AppModel.self) private var model

    let row: ManualBatchPairRow
    let job: EpisodeJob?
    let sourceWidth: CGFloat
    let subtitleWidth: CGFloat
    let targetWidth: CGFloat
    let isExternal: Bool
    let indexGutterWidth: CGFloat
    let statusColWidth: CGFloat
    let rowHeight: CGFloat
    let dragCoordinator: ManualDragCoordinator
    let onSelectCell: (ManualBatchColumnKind, ManualBatchCell?) -> Void
    let onSelectRow: () -> Void
    let onPointerReorderChanged: (ManualBatchColumnKind, ManualBatchCell, CGFloat) -> Void
    let onPointerReorderEnded: (ManualBatchColumnKind) -> Void

    @State private var isHovered = false

    var body: some View {
        let isSelectedRow = model.selectedManualRowIndex == row.index

        HStack(spacing: 0) {
            // Row index gutter (#1, #2, #3...)
            Text("#\(row.index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(isSelectedRow ? Palette.accentText : .secondary)
                .frame(width: indexGutterWidth, height: rowHeight, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelectRow)
                .help("Pair #\(row.index + 1)")

            // Source Video cell
            ManualPairingCellView(
                column: .sourceVideo,
                rowIndex: row.index,
                cell: row.sourceCell,
                job: job,
                rowHeight: rowHeight,
                isSelectedCell: isCellSelected(column: .sourceVideo, cell: row.sourceCell),
                dragCoordinator: dragCoordinator,
                onSelectCell: { onSelectCell(.sourceVideo, row.sourceCell) },
                onPointerReorderChanged: { cell, y in onPointerReorderChanged(.sourceVideo, cell, y) },
                onPointerReorderEnded: { onPointerReorderEnded(.sourceVideo) }
            )
            .frame(width: sourceWidth, height: rowHeight)

            Rectangle()
                .fill(Surfaces.hairline)
                .frame(width: 1, height: rowHeight)

            // Source Subtitles cell (External mode only)
            if isExternal {
                ManualPairingCellView(
                    column: .sourceSubtitle,
                    rowIndex: row.index,
                    cell: row.subtitleCell,
                    job: job,
                    rowHeight: rowHeight,
                    isSelectedCell: isCellSelected(column: .sourceSubtitle, cell: row.subtitleCell),
                    dragCoordinator: dragCoordinator,
                    onSelectCell: { onSelectCell(.sourceSubtitle, row.subtitleCell) },
                    onPointerReorderChanged: { cell, y in onPointerReorderChanged(.sourceSubtitle, cell, y) },
                    onPointerReorderEnded: { onPointerReorderEnded(.sourceSubtitle) }
                )
                .frame(width: subtitleWidth, height: rowHeight)

                Rectangle()
                    .fill(Surfaces.hairline)
                    .frame(width: 1, height: rowHeight)
            }

            // Target Video cell
            ManualPairingCellView(
                column: .targetVideo,
                rowIndex: row.index,
                cell: row.targetCell,
                job: job,
                rowHeight: rowHeight,
                isSelectedCell: isCellSelected(column: .targetVideo, cell: row.targetCell),
                dragCoordinator: dragCoordinator,
                onSelectCell: { onSelectCell(.targetVideo, row.targetCell) },
                onPointerReorderChanged: { cell, y in onPointerReorderChanged(.targetVideo, cell, y) },
                onPointerReorderEnded: { onPointerReorderEnded(.targetVideo) }
            )
            .frame(width: targetWidth, height: rowHeight)

            // Per-row Status Indicator
            ManualRowStatusCell(row: row, job: job)
                .frame(width: statusColWidth, height: rowHeight, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelectRow)
        }
        .background(rowBackground(isSelected: isSelectedRow, isHovered: isHovered))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Surfaces.hairline.opacity(0.45))
                .frame(height: 1)
        }
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
    }

    private func isCellSelected(column: ManualBatchColumnKind, cell: ManualBatchCell?) -> Bool {
        guard let cell, model.selectedManualColumn == column else { return false }
        return model.selectedManualCellIDs.contains(cell.id)
    }

    private func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Palette.accent.opacity(0.14)
        }
        if isHovered {
            return Surfaces.cardHover
        }
        return row.index.isMultiple(of: 2) ? Color.clear : Surfaces.card
    }
}

// MARK: - Pairing Cell View (Direct Pointer Reordering + Full-Filename Hover)

private struct ManualPairingCellView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    let column: ManualBatchColumnKind
    let rowIndex: Int
    let cell: ManualBatchCell?
    let job: EpisodeJob?
    let rowHeight: CGFloat
    let isSelectedCell: Bool
    let dragCoordinator: ManualDragCoordinator
    let onSelectCell: () -> Void
    let onPointerReorderChanged: (ManualBatchCell, CGFloat) -> Void
    let onPointerReorderEnded: () -> Void

    @State private var isHovered = false

    var body: some View {
        Group {
            if let cell, let url = cell.url {
                filledCellView(cell: cell, url: url)
            } else if let cell, cell.isBlankSlot {
                blankSlotView(cell: cell)
            } else {
                missingTrailingSlotView
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelectCell)
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
    }

    private func filledCellView(cell: ManualBatchCell, url: URL) -> some View {
        let colCount = model.manualColumns.cells(in: column).count
        let isDraggingThis = dragCoordinator.isCellBeingReordered(column: column, cellID: cell.id)

        return HStack(spacing: Space.xs) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(isHovered || isDraggingThis ? .secondary : .tertiary)
                .frame(width: 12)

            Text(url.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 2)

            if isHovered && !model.isRunning && !dragCoordinator.isAnyDragActive {
                Button {
                    model.manualRemoveCell(in: column, at: rowIndex, undoManager: undoManager)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .hoverDescription("Remove this item from \(column.title)")
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isDraggingThis ? 0.45 : 1.0)
        .overlay {
            if isSelectedCell {
                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 1)
                    .padding(2)
            }
        }
        .contentShape(Rectangle())
        .help(url.lastPathComponent)
        // Direct pointer drag gesture for instant zero-lag intra-column reordering (no NSItemProvider round-trip)
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("pairingRowsScroll"))
                .onChanged { value in
                    onPointerReorderChanged(cell, value.location.y)
                }
                .onEnded { _ in
                    onPointerReorderEnded()
                }
        )
        .contextMenu {
            Button("Move Up") {
                model.manualMoveUp(in: column, at: rowIndex, undoManager: undoManager)
            }
            .disabled(model.isRunning || rowIndex == 0)

            Button("Move Down") {
                model.manualMoveDown(in: column, at: rowIndex, undoManager: undoManager)
            }
            .disabled(model.isRunning || rowIndex + 1 >= colCount)

            Button("Insert Blank Slot Above") {
                model.manualInsertBlankSlot(in: column, at: rowIndex, undoManager: undoManager)
            }
            .disabled(model.isRunning)

            Button("Insert Blank Slot Below") {
                model.manualInsertBlankSlot(in: column, at: rowIndex + 1, undoManager: undoManager)
            }
            .disabled(model.isRunning)

            Divider()

            Button("Replace File…") {
                model.manualChooseFileForCell(in: column, at: rowIndex, undoManager: undoManager)
            }
            .disabled(model.isRunning)

            Button("Remove from \(column.title)", role: .destructive) {
                if isSelectedCell && model.selectedManualCellIDs.count > 1 {
                    model.manualRemoveSelectedCells(undoManager: undoManager)
                } else {
                    model.manualRemoveCell(in: column, at: rowIndex, undoManager: undoManager)
                }
            }
            .disabled(model.isRunning)

            Divider()

            Button("Reveal in Finder") {
                model.revealInFinder(url.path)
            }

            if let job, let firstWarn = job.warnings.first {
                Button("Jump to Warning in Log") {
                    model.selectedManualRowIndex = rowIndex
                    model.jumpToWarning(firstWarn, in: job)
                }
            }

            if let job, job.hasPairedFiles && (job.status == .failed || job.status == .warned || job.status == .cancelled) {
                Button("Retry Pair #\(rowIndex + 1)") {
                    job.resetForRetry()
                    model.startManualBatchQueue()
                }
            }

            if let job, job.canMergeManually && model.dependencies.isInstalled(.mkvmerge) {
                Button("Merge MKV") {
                    model.selectedManualRowIndex = rowIndex
                    model.mergeCompletedJobs()
                }
            }
        }
    }

    private func blankSlotView(cell: ManualBatchCell) -> some View {
        let colCount = model.manualColumns.cells(in: column).count
        let isDraggingThis = dragCoordinator.isCellBeingReordered(column: column, cellID: cell.id)

        return HStack(spacing: Space.xs) {
            Image(systemName: "rectangle.dashed")
                .font(.caption2)
                .foregroundStyle(Surfaces.statusWarning)
            Text("Blank Slot")
                .font(.caption)
                .foregroundStyle(Surfaces.statusWarning)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isHovered && !model.isRunning && !dragCoordinator.isAnyDragActive {
                Button {
                    model.manualRemoveCell(in: column, at: rowIndex, undoManager: undoManager)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .hoverDescription("Remove blank alignment slot")
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isDraggingThis ? 0.45 : 1.0)
        .background(
            Surfaces.statusWarning.opacity(0.06),
            in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .strokeBorder(
                    isSelectedCell ? Palette.accent : Surfaces.statusWarning.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help("Blank alignment slot — drop a file here or right-click to choose or remove")
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("pairingRowsScroll"))
                .onChanged { value in
                    onPointerReorderChanged(cell, value.location.y)
                }
                .onEnded { _ in
                    onPointerReorderEnded()
                }
        )
        .contextMenu {
            Button("Choose File…") {
                model.manualChooseFileForCell(in: column, at: rowIndex, undoManager: undoManager)
            }
            .disabled(model.isRunning)

            Button("Move Up") {
                model.manualMoveUp(in: column, at: rowIndex, undoManager: undoManager)
            }
            .disabled(model.isRunning || rowIndex == 0)

            Button("Move Down") {
                model.manualMoveDown(in: column, at: rowIndex, undoManager: undoManager)
            }
            .disabled(model.isRunning || rowIndex + 1 >= colCount)

            Divider()

            Button("Remove Blank Slot", role: .destructive) {
                model.manualRemoveCell(in: column, at: rowIndex, undoManager: undoManager)
            }
            .disabled(model.isRunning)
        }
    }

    private var missingTrailingSlotView: some View {
        HStack(spacing: Space.xs) {
            Text("Empty Slot")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .strokeBorder(
                    Surfaces.statusWarning.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help("Empty slot in \(column.title) — drop a file here or right-click to choose")
        .contextMenu {
            Button("Choose File…") {
                model.manualChooseFileForCell(in: column, at: rowIndex, undoManager: undoManager)
            }
            .disabled(model.isRunning)

            Button("Insert Blank Slot Here") {
                model.manualInsertBlankSlot(in: column, at: rowIndex, undoManager: undoManager)
            }
            .disabled(model.isRunning)
        }
    }
}

// MARK: - Isolated Column-Level Drop Target, Incompatible Dimming & Zero-Lag Insertion Line

private struct ManualColumnHeaderDimOverlay: View {
    let column: ManualBatchColumnKind
    let coordinator: ManualDragCoordinator

    var body: some View {
        if coordinator.isColumnIncompatible(column) {
            Rectangle()
                .fill(.windowBackground.opacity(0.58))
                .allowsHitTesting(false)
        }
    }
}

private struct ManualColumnDropHitTarget: View {
    let column: ManualBatchColumnKind
    let width: CGFloat
    let height: CGFloat
    let rowHeight: CGFloat
    let itemCount: Int
    let coordinator: ManualDragCoordinator
    let onCommitDrop: @MainActor ([URL], Int?, Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onDrop(
                of: [.json, .fileURL],
                delegate: ManualColumnDropDelegate(
                    column: column,
                    rowHeight: rowHeight,
                    itemCount: itemCount,
                    coordinator: coordinator,
                    onCommitDrop: onCommitDrop
                )
            )
    }
}

private struct ManualColumnVisualOverlay: View {
    let column: ManualBatchColumnKind
    let width: CGFloat
    let height: CGFloat
    let rowHeight: CGFloat
    let coordinator: ManualDragCoordinator

    var body: some View {
        let isIncompatible = coordinator.isColumnIncompatible(column)
        let isActiveTarget = !isIncompatible && coordinator.dropTargetColumn == column
        let insertSlot = isActiveTarget ? coordinator.dropInsertIndex : nil

        ZStack(alignment: .topLeading) {
            if isActiveTarget && coordinator.reorderColumn == nil {
                Rectangle()
                    .fill(Palette.accent.opacity(0.06))
                    .overlay(
                        Rectangle()
                            .strokeBorder(Palette.accent.opacity(0.55), lineWidth: 1)
                    )
            }

            if isIncompatible {
                Rectangle()
                    .fill(.windowBackground.opacity(0.58))
                    .overlay(
                        Rectangle()
                            .fill(Surfaces.hairline.opacity(0.25))
                    )
            }

            if let slot = insertSlot {
                let lineY = max(0, min(CGFloat(slot) * rowHeight, height - 2))
                VStack(spacing: 0) {
                    if lineY > 0 {
                        Color.clear.frame(height: lineY)
                    }
                    HStack(spacing: 0) {
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: 8, height: 8)
                        Rectangle()
                            .fill(Palette.accent)
                            .frame(height: 2)
                    }
                    .padding(.horizontal, Space.xs)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct ManualColumnDropDelegate: DropDelegate {
    let column: ManualBatchColumnKind
    let rowHeight: CGFloat
    let itemCount: Int
    let coordinator: ManualDragCoordinator
    let onCommitDrop: @MainActor ([URL], Int?, Bool) -> Void

    private func computeSlotIndex(for location: CGPoint) -> Int {
        let raw = Int((location.y / rowHeight).rounded())
        return max(0, min(raw, itemCount))
    }

    func validateDrop(info: DropInfo) -> Bool {
        if coordinator.isColumnIncompatible(column) {
            return false
        }
        return info.hasItemsConforming(to: [.json, .fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard !coordinator.isColumnIncompatible(column) else { return }
        coordinator.updateDropTarget(column: column, index: computeSlotIndex(for: info.location))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if coordinator.isColumnIncompatible(column) {
            if coordinator.dropTargetColumn == column {
                coordinator.updateDropTarget(column: nil, index: nil)
            }
            return DropProposal(operation: .forbidden)
        }
        coordinator.updateDropTarget(column: column, index: computeSlotIndex(for: info.location))
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if coordinator.dropTargetColumn == column {
            coordinator.updateDropTarget(column: nil, index: nil)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        if coordinator.isColumnIncompatible(column) {
            coordinator.endAllDrags()
            return false
        }

        let targetSlot = computeSlotIndex(for: info.location)
        let insertionIndex: Int? = targetSlot >= itemCount ? nil : targetSlot

        // Fast synchronous path for File Browser drags (zero NSItemProvider JSON decode latency!)
        if let localURLs = coordinator.consumeBrowserDragURLs() {
            onCommitDrop(localURLs, insertionIndex, true)
            return true
        }

        coordinator.endAllDrags()

        // Fallback JSON path (if needed)
        let jsonProviders = info.itemProviders(for: [.json])
        if let jsonProvider = jsonProviders.first {
            let commit = onCommitDrop
            let targetColumn = column
            jsonProvider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
                guard let data,
                      let transfer = try? JSONDecoder().decode(ManualDragTransfer.self, from: data),
                      transfer.sushiManualTransfer else { return }
                if let kind = transfer.itemKind, !kind.acceptsColumn(targetColumn) {
                    return
                }
                let urls = transfer.filePaths.map { URL(fileURLWithPath: $0) }
                Task { @MainActor in
                    commit(urls, insertionIndex, true)
                }
            }
            return true
        }

        // External macOS Finder drop (single files, multi-file selection, or folders)
        let urlProviders = info.itemProviders(for: [.fileURL])
        let commit = onCommitDrop
        return DroppedFileURLLoader.load(from: urlProviders) { urls in
            commit(urls, insertionIndex, true)
        }
    }
}

// MARK: - Per-Row Status Indicator & Empty Placeholders

private struct ManualRowStatusCell: View {
    let row: ManualBatchPairRow
    let job: EpisodeJob?

    var body: some View {
        let info = statusInfo
        Label(info.label, systemImage: info.symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(info.color)
            .lineLimit(1)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 2)
            .background(info.color.opacity(0.14), in: Capsule())
            .hoverDescription(info.help)
    }

    private var statusInfo: (label: String, symbol: String, color: Color, help: String) {
        if !row.isComplete {
            return (
                "Incomplete",
                "exclamationmark.circle",
                Surfaces.statusWarning,
                "Missing a required file in this row — will be skipped when running"
            )
        }
        guard let job else {
            return ("Ready", "circle", .secondary, "Pair is complete and ready to sync")
        }
        switch job.status {
        case .pending:
            return ("Ready", "circle", .secondary, "Pair is complete and ready to sync")
        case .running:
            return ("Running", "arrow.trianglehead.2.clockwise", Surfaces.statusRunning, job.stageDetail.isEmpty ? "Syncing…" : job.stageDetail)
        case .succeeded:
            return ("Success", "checkmark.circle.fill", Surfaces.statusSuccess, "Synced cleanly")
        case .warned:
            return ("Warning", "exclamationmark.triangle.fill", Surfaces.statusWarning, job.warningBannerSummary ?? "Completed with warnings")
        case .failed:
            return ("Failed", "xmark.octagon.fill", Surfaces.statusError, job.errorMessage ?? "Sync failed")
        case .cancelled:
            return ("Cancelled", "slash.circle", .secondary, "Cancelled")
        }
    }
}

private struct ManualEmptyColumnPlaceholder: View {
    let column: ManualBatchColumnKind
    let prompt: String
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: column == .sourceSubtitle ? "captions.bubble" : "film")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add Files…", action: onAdd)
                .controlSize(.mini)
                .hoverDescription("Choose files or folders to add to \(column.title)")
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surfaces.dropZone)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(
                    Surfaces.hairline,
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
                .padding(Space.sm)
        )
    }
}

// MARK: - Interactive Resizable Column Divider

private struct ColumnResizeDivider: View {
    let height: CGFloat
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onDoubleClickReset: () -> Void

    @State private var isHovered = false
    @State private var isDragging = false
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(isDragging || isHovered ? Palette.accent.opacity(0.75) : Surfaces.hairline)
            .frame(width: 1, height: height)
            .overlay {
                Color.clear
                    .frame(width: 8, height: height)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovered = hovering
                        if hovering && !cursorPushed {
                            NSCursor.resizeLeftRight.push()
                            cursorPushed = true
                        } else if !hovering && cursorPushed {
                            NSCursor.pop()
                            cursorPushed = false
                        }
                    }
                    .onDisappear {
                        if cursorPushed {
                            NSCursor.pop()
                            cursorPushed = false
                        }
                    }
                    .onTapGesture(count: 2) {
                        onDoubleClickReset()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("manualBatchColumns"))
                            .onChanged { value in
                                isDragging = true
                                onDragChanged(value.translation.width)
                            }
                            .onEnded { _ in
                                isDragging = false
                                onDragEnded()
                            }
                    )
            }
            .help("Drag to resize column width (double-click to reset)")
    }
}

// MARK: - Drag Preview & Finder Multi-URL Collector

private struct DragBadgePreview: View {
    let count: Int
    let title: String

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: count > 1 ? "doc.on.doc" : "doc")
                .font(.caption)
                .foregroundStyle(Palette.accentText)
            Text(count > 1 ? "\(count) items" : title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.5), lineWidth: 1)
        )
    }
}
