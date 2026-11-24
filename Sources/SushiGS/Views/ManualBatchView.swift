import AppKit
import SwiftUI
import SushiGSKit
import UniformTypeIdentifiers

// MARK: - Internal Drag Payload (Browser Multi-Select & Single-Column Reorder)

private nonisolated struct ManualDragTransfer: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case browserFiles
        case columnReorder
    }

    var sushiManualTransfer: Bool = true
    var kind: Kind
    var filePaths: [String]
    var sourceColumn: ManualBatchColumnKind?
    var cellIDs: [UUID]
    var sourceIndex: Int?
}

// MARK: - Manual Batch Workspace

struct ManualBatchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    @AppStorage("manualBatch.browserWidth") private var storedBrowserWidth: Double = 192
    @AppStorage("manualBatch.embeddedSourceRatio") private var storedEmbeddedSourceRatio: Double = 0.50
    @AppStorage("manualBatch.externalSourceRatio") private var storedExternalSourceRatio: Double = 0.32
    @AppStorage("manualBatch.externalSubtitleRatio") private var storedExternalSubtitleRatio: Double = 0.36

    @State private var showTrackRulesPopover = false
    @State private var hoveredRowIndex: Int?
    @State private var isBrowserDropTargeted = false
    @State private var dragStartBrowserWidth: CGFloat?
    @State private var dragStartSourceRatio: Double?
    @State private var dragStartSubtitleRatio: Double?

    private let rowHeight: CGFloat = 32
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

            Divider()

            resizableColumnWorkspace
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()

            if let selectedJob = selectedManualJob, shouldShowSelectedDetailStrip(selectedJob) {
                Divider()
                selectedRowDetailStrip(job: selectedJob)
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, Space.sm)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .gridArea("manual", inset: Space.margin)
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

    // MARK: - Resizable Multi-Column Split Layout

    private var resizableColumnWorkspace: some View {
        let isExternal = model.manualColumns.subtitleMode == .external

        return GeometryReader { geo in
            let totalWidth = max(geo.size.width, 520)
            let totalHeight = max(geo.size.height, 160)
            let scrollViewportHeight = max(totalHeight - columnHeaderHeight - 1, 100)
            let minBrowser: CGFloat = 160
            let maxBrowser: CGFloat = min(420, totalWidth * 0.44)
            let browserWidth = min(max(CGFloat(storedBrowserWidth), minBrowser), maxBrowser)
            let pairingAreaWidth = max(totalWidth - browserWidth - 1, 320)
            let dividerCount: CGFloat = isExternal ? 2 : 1
            let dataColsWidth = max(pairingAreaWidth - indexGutterWidth - statusColWidth - dividerCount, 200)

            let columnWidths = computeColumnWidths(
                dataColsWidth: dataColsWidth,
                isExternal: isExternal
            )

            HStack(spacing: 0) {
                // Column 1: Lightweight Native File Browser
                ManualFileBrowserPane(
                    headerHeight: columnHeaderHeight,
                    isDropTargeted: $isBrowserDropTargeted,
                    onAddFilesToColumn: { urls, col in
                        model.manualInsert(urls: urls, into: col, at: nil, expandDirectories: true, undoManager: undoManager)
                    }
                )
                .frame(width: browserWidth, height: totalHeight, alignment: .topLeading)

                // Resizable Divider 0: File Browser | Pairing Columns
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
                        storedBrowserWidth = 192
                    }
                )

                // Columns 2–4: Synchronized Pairing Workspace
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        pairingHeadersRow(columnWidths: columnWidths, isExternal: isExternal)
                            .frame(width: pairingAreaWidth, height: columnHeaderHeight)
                            .background(Surfaces.card)

                        Divider()

                        pairingScrollBody(
                            columnWidths: columnWidths,
                            isExternal: isExternal,
                            viewportHeight: scrollViewportHeight
                        )
                        .frame(width: pairingAreaWidth, height: scrollViewportHeight)
                    }
                    .frame(width: pairingAreaWidth, height: totalHeight, alignment: .topLeading)

                    // Full-height interactive column resize handles spanning both header and rows
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
                                    storedExternalSourceRatio = 0.32
                                    storedExternalSubtitleRatio = 0.36
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
                                    storedExternalSourceRatio = 0.32
                                    storedExternalSubtitleRatio = 0.36
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

    private struct PairingColumnWidths {
        let sourceWidth: CGFloat
        let subtitleWidth: CGFloat
        let targetWidth: CGFloat
    }

    private func computeColumnWidths(dataColsWidth: CGFloat, isExternal: Bool) -> PairingColumnWidths {
        if isExternal {
            let minCol: CGFloat = 96
            let maxSrc = max(minCol, dataColsWidth - 2 * minCol)
            let srcW = min(max(dataColsWidth * CGFloat(storedExternalSourceRatio), minCol), maxSrc)
            let maxSub = max(minCol, dataColsWidth - srcW - minCol)
            let subW = min(max(dataColsWidth * CGFloat(storedExternalSubtitleRatio), minCol), maxSub)
            let dstW = max(dataColsWidth - srcW - subW, minCol)
            return PairingColumnWidths(sourceWidth: srcW, subtitleWidth: subW, targetWidth: dstW)
        } else {
            let minCol: CGFloat = 100
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

            pairingColumnHeader(column: .sourceVideo)
                .frame(width: columnWidths.sourceWidth, height: columnHeaderHeight)

            Rectangle()
                .fill(Surfaces.hairline)
                .frame(width: 1, height: columnHeaderHeight)

            if isExternal {
                pairingColumnHeader(column: .sourceSubtitle)
                    .frame(width: columnWidths.subtitleWidth, height: columnHeaderHeight)

                Rectangle()
                    .fill(Surfaces.hairline)
                    .frame(width: 1, height: columnHeaderHeight)
            }

            pairingColumnHeader(column: .targetVideo)
                .frame(width: columnWidths.targetWidth, height: columnHeaderHeight)

            Text("Status")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: statusColWidth, alignment: .center)
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
            }

            HStack(spacing: Space.sm) {
                Button {
                    model.manualPickFiles(for: column, undoManager: undoManager)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isRunning)
                .help("Add files or folders to \(column.title)")

                Button {
                    model.manualSortColumn(column, undoManager: undoManager)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasItems ? .secondary : .tertiary)
                .disabled(model.isRunning || count < 2)
                .help("Sort \(column.title) A–Z (Natural Finder order)")

                Button {
                    model.manualReverseColumn(column, undoManager: undoManager)
                } label: {
                    Image(systemName: "arrow.uturn.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasItems ? .secondary : .tertiary)
                .disabled(model.isRunning || model.manualColumns.cells(in: column).count < 2)
                .help("Reverse order of \(column.title)")

                Spacer(minLength: 0)

                Button {
                    model.manualClearColumn(column, undoManager: undoManager)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasItems ? .secondary : .tertiary)
                .disabled(model.isRunning || !hasItems)
                .help("Clear all items in \(column.title)")
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
            let minRatio = Double(96 / dataColsWidth)
            let combined = baseSrc + baseSub
            let nextSrc = min(max(baseSrc + Double(delta / dataColsWidth), minRatio), combined - minRatio)
            storedExternalSourceRatio = nextSrc
            storedExternalSubtitleRatio = max(minRatio, combined - nextSrc)
        } else {
            if dragStartSourceRatio == nil {
                dragStartSourceRatio = Double(current.sourceWidth / dataColsWidth)
            }
            let baseSrc = dragStartSourceRatio ?? storedEmbeddedSourceRatio
            let minRatio = Double(100 / dataColsWidth)
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
        let minRatio = Double(96 / dataColsWidth)
        let maxSub = max(minRatio, 1.0 - srcRatio - minRatio)
        storedExternalSubtitleRatio = min(max(baseSub + Double(delta / dataColsWidth), minRatio), maxSub)
    }

    // MARK: - Synchronized Scrollable Pairing Rows

    private func pairingScrollBody(
        columnWidths: PairingColumnWidths,
        isExternal: Bool,
        viewportHeight: CGFloat
    ) -> some View {
        let rows = model.manualColumns.rows
        let tailHeight = max(64, viewportHeight - CGFloat(rows.count) * rowHeight)

        return ScrollView {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    emptyColumnsDropCanvas(
                        columnWidths: columnWidths,
                        isExternal: isExternal,
                        canvasHeight: max(viewportHeight, 160)
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.index) { row in
                            pairedRowView(
                                row: row,
                                job: model.manualJobs.indices.contains(row.index) ? model.manualJobs[row.index] : nil,
                                columnWidths: columnWidths,
                                isExternal: isExternal
                            )
                        }
                    }

                    // Trailing drop tail so users can always append to any column below existing rows
                    trailingDropTail(
                        columnWidths: columnWidths,
                        isExternal: isExternal,
                        tailHeight: tailHeight
                    )
                }
            }
        }
    }

    private func pairedRowView(
        row: ManualBatchPairRow,
        job: EpisodeJob?,
        columnWidths: PairingColumnWidths,
        isExternal: Bool
    ) -> some View {
        let isSelectedRow = model.selectedManualRowIndex == row.index
        let isHoveredRow = hoveredRowIndex == row.index

        return HStack(spacing: 0) {
            // Row index gutter (#1, #2, #3...)
            Text("#\(row.index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(isSelectedRow ? Palette.accentText : .secondary)
                .frame(width: indexGutterWidth, height: rowHeight, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedManualRowIndex = row.index
                    model.selectedManualColumn = nil
                    model.selectedManualCellIDs.removeAll()
                }

            // Column 2: Source Video
            ManualPairingCellView(
                column: .sourceVideo,
                rowIndex: row.index,
                cell: row.sourceCell,
                job: job,
                rowHeight: rowHeight,
                isSelectedCell: isCellSelected(column: .sourceVideo, cell: row.sourceCell),
                onSelectCell: { handleCellClick(column: .sourceVideo, rowIndex: row.index, cell: row.sourceCell) },
                onDropPayload: { handleCellDrop(providers: $0, column: .sourceVideo, rowIndex: row.index) },
                onDragProvider: { makeCellDragProvider(column: .sourceVideo, rowIndex: row.index, cell: $0) },
                dragBadgeCount: { dragCountForCell(column: .sourceVideo, cell: $0) }
            )
            .frame(width: columnWidths.sourceWidth, height: rowHeight)

            Rectangle()
                .fill(Surfaces.hairline)
                .frame(width: 1, height: rowHeight)

            // Column 3 (External mode): Source Subtitles
            if isExternal {
                ManualPairingCellView(
                    column: .sourceSubtitle,
                    rowIndex: row.index,
                    cell: row.subtitleCell,
                    job: job,
                    rowHeight: rowHeight,
                    isSelectedCell: isCellSelected(column: .sourceSubtitle, cell: row.subtitleCell),
                    onSelectCell: { handleCellClick(column: .sourceSubtitle, rowIndex: row.index, cell: row.subtitleCell) },
                    onDropPayload: { handleCellDrop(providers: $0, column: .sourceSubtitle, rowIndex: row.index) },
                    onDragProvider: { makeCellDragProvider(column: .sourceSubtitle, rowIndex: row.index, cell: $0) },
                    dragBadgeCount: { dragCountForCell(column: .sourceSubtitle, cell: $0) }
                )
                .frame(width: columnWidths.subtitleWidth, height: rowHeight)

                Rectangle()
                    .fill(Surfaces.hairline)
                    .frame(width: 1, height: rowHeight)
            }

            // Target Video column
            ManualPairingCellView(
                column: .targetVideo,
                rowIndex: row.index,
                cell: row.targetCell,
                job: job,
                rowHeight: rowHeight,
                isSelectedCell: isCellSelected(column: .targetVideo, cell: row.targetCell),
                onSelectCell: { handleCellClick(column: .targetVideo, rowIndex: row.index, cell: row.targetCell) },
                onDropPayload: { handleCellDrop(providers: $0, column: .targetVideo, rowIndex: row.index) },
                onDragProvider: { makeCellDragProvider(column: .targetVideo, rowIndex: row.index, cell: $0) },
                dragBadgeCount: { dragCountForCell(column: .targetVideo, cell: $0) }
            )
            .frame(width: columnWidths.targetWidth, height: rowHeight)

            // Per-row Status Indicator
            ManualRowStatusCell(row: row, job: job)
                .frame(width: statusColWidth, height: rowHeight, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedManualRowIndex = row.index
                }
        }
        .background(rowBackground(index: row.index, isSelected: isSelectedRow, isHovered: isHoveredRow))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Surfaces.hairline.opacity(0.45))
                .frame(height: 1)
        }
        .onHover { hovering in
            if hovering {
                hoveredRowIndex = row.index
            } else if hoveredRowIndex == row.index {
                hoveredRowIndex = nil
            }
        }
    }

    private func rowBackground(index: Int, isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Palette.accent.opacity(0.14)
        }
        if isHovered {
            return Surfaces.cardHover
        }
        return index.isMultiple(of: 2) ? Color.clear : Surfaces.card
    }

    private func emptyColumnsDropCanvas(
        columnWidths: PairingColumnWidths,
        isExternal: Bool,
        canvasHeight: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: indexGutterWidth, height: canvasHeight)

            ManualEmptyColumnDropTarget(
                column: .sourceVideo,
                prompt: "Drop source videos or folders",
                onAdd: { model.manualPickFiles(for: .sourceVideo, undoManager: undoManager) },
                onDropProviders: { handleCellDrop(providers: $0, column: .sourceVideo, rowIndex: nil) }
            )
            .frame(width: columnWidths.sourceWidth, height: canvasHeight)

            Rectangle()
                .fill(Surfaces.hairline)
                .frame(width: 1, height: canvasHeight)

            if isExternal {
                ManualEmptyColumnDropTarget(
                    column: .sourceSubtitle,
                    prompt: "Drop .ass, .srt, .ssa files or folders",
                    onAdd: { model.manualPickFiles(for: .sourceSubtitle, undoManager: undoManager) },
                    onDropProviders: { handleCellDrop(providers: $0, column: .sourceSubtitle, rowIndex: nil) }
                )
                .frame(width: columnWidths.subtitleWidth, height: canvasHeight)

                Rectangle()
                    .fill(Surfaces.hairline)
                    .frame(width: 1, height: canvasHeight)
            }

            ManualEmptyColumnDropTarget(
                column: .targetVideo,
                prompt: "Drop target videos or folders",
                onAdd: { model.manualPickFiles(for: .targetVideo, undoManager: undoManager) },
                onDropProviders: { handleCellDrop(providers: $0, column: .targetVideo, rowIndex: nil) }
            )
            .frame(width: columnWidths.targetWidth, height: canvasHeight)

            Color.clear
                .frame(width: statusColWidth, height: canvasHeight)
        }
        .frame(height: canvasHeight)
    }

    private func trailingDropTail(
        columnWidths: PairingColumnWidths,
        isExternal: Bool,
        tailHeight: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: indexGutterWidth, height: tailHeight)

            ManualColumnTailDropZone(
                column: .sourceVideo,
                onDropProviders: { handleCellDrop(providers: $0, column: .sourceVideo, rowIndex: nil) }
            )
            .frame(width: columnWidths.sourceWidth, height: tailHeight)

            Rectangle()
                .fill(Surfaces.hairline)
                .frame(width: 1, height: tailHeight)

            if isExternal {
                ManualColumnTailDropZone(
                    column: .sourceSubtitle,
                    onDropProviders: { handleCellDrop(providers: $0, column: .sourceSubtitle, rowIndex: nil) }
                )
                .frame(width: columnWidths.subtitleWidth, height: tailHeight)

                Rectangle()
                    .fill(Surfaces.hairline)
                    .frame(width: 1, height: tailHeight)
            }

            ManualColumnTailDropZone(
                column: .targetVideo,
                onDropProviders: { handleCellDrop(providers: $0, column: .targetVideo, rowIndex: nil) }
            )
            .frame(width: columnWidths.targetWidth, height: tailHeight)

            Color.clear
                .frame(width: statusColWidth, height: tailHeight)
        }
        .frame(height: tailHeight)
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
                    }
                    if let mkv = job.mergedFilepath {
                        Button("Reveal Merged MKV", systemImage: "film.stack") {
                            model.revealInFinder(mkv)
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Cell Selection, Drag & Drop Helpers

    private func isCellSelected(column: ManualBatchColumnKind, cell: ManualBatchCell?) -> Bool {
        guard let cell, model.selectedManualColumn == column else { return false }
        return model.selectedManualCellIDs.contains(cell.id)
    }

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

    private func dragCountForCell(column: ManualBatchColumnKind, cell: ManualBatchCell) -> Int {
        if model.selectedManualColumn == column, model.selectedManualCellIDs.contains(cell.id) {
            return max(1, model.selectedManualCellIDs.count)
        }
        return 1
    }

    private func makeCellDragProvider(
        column: ManualBatchColumnKind,
        rowIndex: Int,
        cell: ManualBatchCell
    ) -> NSItemProvider {
        let ids: [UUID]
        if model.selectedManualColumn == column, model.selectedManualCellIDs.contains(cell.id) {
            ids = model.manualColumns.cells(in: column)
                .filter { model.selectedManualCellIDs.contains($0.id) }
                .map(\.id)
        } else {
            ids = [cell.id]
        }

        let payload = ManualDragTransfer(
            kind: .columnReorder,
            filePaths: cell.url.map { [$0.path] } ?? [],
            sourceColumn: column,
            cellIDs: ids,
            sourceIndex: rowIndex
        )
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.json.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    private func handleCellDrop(
        providers: [NSItemProvider],
        column: ManualBatchColumnKind,
        rowIndex: Int?
    ) -> Bool {
        let onTransfer: @MainActor (ManualDragTransfer) -> Void = { transfer in
            switch transfer.kind {
            case .browserFiles:
                let urls = transfer.filePaths.map { URL(fileURLWithPath: $0) }
                model.manualInsert(
                    urls: urls,
                    into: column,
                    at: rowIndex,
                    expandDirectories: true,
                    undoManager: undoManager
                )
            case .columnReorder:
                if transfer.sourceColumn == column {
                    let dest = rowIndex ?? model.manualColumns.cells(in: column).count
                    model.manualMoveCells(
                        in: column,
                        ids: Set(transfer.cellIDs),
                        to: dest,
                        undoManager: undoManager
                    )
                } else if !transfer.filePaths.isEmpty {
                    let urls = transfer.filePaths.map { URL(fileURLWithPath: $0) }
                    model.manualInsert(
                        urls: urls,
                        into: column,
                        at: rowIndex,
                        expandDirectories: false,
                        undoManager: undoManager
                    )
                }
            }
        }

        // 1. Check for internal ManualDragTransfer JSON (from File Browser or Column Reorder)
        if let jsonProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.json.identifier) }) {
            jsonProvider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
                guard let data,
                      let transfer = try? JSONDecoder().decode(ManualDragTransfer.self, from: data),
                      transfer.sushiManualTransfer else { return }
                Task { @MainActor in
                    onTransfer(transfer)
                }
            }
            return true
        }

        // 2. External drop from macOS Finder (files or folders)
        let urlProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !urlProviders.isEmpty else { return false }
        let onURLs: @MainActor ([URL]) -> Void = { urls in
            model.manualInsert(
                urls: urls,
                into: column,
                at: rowIndex,
                expandDirectories: true,
                undoManager: undoManager
            )
        }
        let collector = ManualURLDropCollector(total: urlProviders.count, completion: onURLs)
        for provider in urlProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in collector.record(url) }
            }
        }
        return true
    }
}

// MARK: - Column 1: Lightweight Native File Browser

private struct ManualFileBrowserPane: View {
    @Environment(AppModel.self) private var model
    let headerHeight: CGFloat
    @Binding var isDropTargeted: Bool
    let onAddFilesToColumn: ([URL], ManualBatchColumnKind) -> Void

    private struct FlattenedNode: Identifiable {
        let entry: FileBrowserEntry
        let depth: Int
        var id: String { entry.id }
    }

    var body: some View {
        @Bindable var model = model
        let visibleNodes = flattenedVisibleNodes()

        VStack(spacing: 0) {
            // Browser header (48 pt height matching pairing column headers)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text("File Browser")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Button("Choose…") {
                        model.chooseManualBrowserFolder()
                    }
                    .controlSize(.mini)
                    .help("Choose a folder to browse")

                    Button {
                        model.refreshManualBrowser()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.manualBrowserRootURL == nil)
                    .help("Refresh current folder")
                }

                breadcrumbBar
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .frame(height: headerHeight)
            .background(Surfaces.card)

            Divider()

            // Search box + All / Video / Subtitles filter pills
            VStack(spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Filter files…", text: $model.manualBrowserSearch)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !model.manualBrowserSearch.isEmpty {
                        Button {
                            model.manualBrowserSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear filter text")
                    }
                }
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xs)
                .background(Surfaces.card, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                        .strokeBorder(Surfaces.hairline, lineWidth: 1)
                )

                HStack(spacing: Space.xs) {
                    ForEach(FileBrowserFilter.allCases) { filter in
                        let selected = model.manualBrowserFilter == filter
                        Button(filter.displayName) {
                            model.manualBrowserFilter = filter
                        }
                        .buttonStyle(.plain)
                        .font(.caption2.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Palette.onAccent : .primary)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 2)
                        .background(selected ? Palette.accent : Surfaces.card, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)

            Divider()

            // Independent scrollable file tree
            if model.manualBrowserRootURL == nil {
                VStack(spacing: Space.sm) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Drop a folder here or choose one to browse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Choose Folder…") {
                        model.chooseManualBrowserFolder()
                    }
                    .controlSize(.small)
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
                            browserRow(node: node, allVisible: visibleNodes)
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onKeyPress(characters: CharacterSet(charactersIn: "aA"), phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    selectAllVisibleFiles(in: visibleNodes)
                    return .handled
                }
            }
        }
        .background(isDropTargeted ? Palette.accent.opacity(0.08) : Color.clear)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 2)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let first = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
                return false
            }
            let onRoot: @MainActor (URL) -> Void = { droppedURL in
                model.setManualBrowserRoot(droppedURL)
            }
            _ = first.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    onRoot(url)
                }
            }
            return true
        }
    }

    @ViewBuilder
    private var breadcrumbBar: some View {
        if let root = model.manualBrowserRootURL {
            let canGoUp = root.deletingLastPathComponent().path != root.path
            let segments = breadcrumbSegments(for: root)

            HStack(spacing: Space.xs) {
                Button {
                    model.navigateManualBrowserUp()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.turn.left.up")
                            .font(.caption2)
                        Text("..")
                            .font(.caption2.monospaced())
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(canGoUp ? .secondary : .tertiary)
                .disabled(!canGoUp)
                .help("Go to parent folder")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
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
                            .font(.caption2.weight(idx == segments.count - 1 ? .semibold : .regular))
                            .foregroundStyle(idx == segments.count - 1 ? .primary : .secondary)
                            .lineLimit(1)
                            .help(seg.url.path)
                        }
                    }
                }
            }
        } else {
            Text("No folder selected")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func breadcrumbSegments(for url: URL) -> [(name: String, url: URL)] {
        var list: [(String, URL)] = []
        var cursor = url.standardizedFileURL
        for _ in 0..<4 {
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

    private func browserRow(node: FlattenedNode, allVisible: [FlattenedNode]) -> some View {
        let entry = node.entry
        let isSelected = model.manualBrowserSelectedPaths.contains(entry.id)
        let isExpanded = model.manualBrowserExpandedPaths.contains(entry.id)
        let indent = CGFloat(node.depth) * Space.md

        return HStack(spacing: Space.xs) {
            if entry.isDirectory {
                Button {
                    model.toggleManualBrowserExpanded(entry.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 16)
                }
                .buttonStyle(.plain)
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
                .help(entry.url.path)

            Spacer(minLength: 0)
        }
        .padding(.leading, Space.xs + indent)
        .padding(.trailing, Space.xs)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.accent : Color.clear, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        .padding(.horizontal, Space.xs)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isDirectory {
                model.setManualBrowserRoot(entry.url)
            }
        }
        .onTapGesture(count: 1) {
            handleBrowserSelection(entry: entry, allVisible: allVisible)
        }
        .onDrag {
            makeBrowserDragProvider(for: entry, allVisible: allVisible)
        } preview: {
            let items = targetURLsForAction(clicked: entry, allVisible: allVisible)
            DragBadgePreview(count: items.count, title: entry.name)
        }
        .contextMenu {
            let urls = targetURLsForAction(clicked: entry, allVisible: allVisible)
            let suffix = urls.count > 1 ? " (\(urls.count))" : ""

            Button("Add to Source Video\(suffix)") {
                onAddFilesToColumn(urls, .sourceVideo)
            }
            .disabled(model.isRunning)

            Button("Add to Source Subtitles\(suffix)") {
                onAddFilesToColumn(urls, .sourceSubtitle)
            }
            .disabled(model.isRunning)

            Button("Add to Target Video\(suffix)") {
                onAddFilesToColumn(urls, .targetVideo)
            }
            .disabled(model.isRunning)

            Divider()

            if entry.isDirectory {
                Button("Open Folder") {
                    model.setManualBrowserRoot(entry.url)
                }
            }

            Button("Select All Files") {
                selectAllVisibleFiles(in: allVisible)
            }

            Button("Reveal in Finder") {
                model.revealInFinder(entry.url.path)
            }
        }
    }

    private func iconColor(for entry: FileBrowserEntry, isSelected: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Palette.onAccent) }
        if entry.isDirectory { return AnyShapeStyle(Palette.accentText) }
        if entry.isSubtitle { return AnyShapeStyle(Surfaces.statusRunning) }
        if entry.isMedia { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tertiary)
    }

    private func handleBrowserSelection(entry: FileBrowserEntry, allVisible: [FlattenedNode]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.manualBrowserSelectedPaths.contains(entry.id) {
                model.manualBrowserSelectedPaths.remove(entry.id)
            } else {
                model.manualBrowserSelectedPaths.insert(entry.id)
                model.manualBrowserAnchorPath = entry.id
            }
        } else if flags.contains(.shift),
                  let anchor = model.manualBrowserAnchorPath,
                  let anchorIdx = allVisible.firstIndex(where: { $0.id == anchor }),
                  let clickIdx = allVisible.firstIndex(where: { $0.id == entry.id }) {
            let lo = min(anchorIdx, clickIdx)
            let hi = max(anchorIdx, clickIdx)
            model.manualBrowserSelectedPaths = Set(allVisible[lo...hi].map(\.id))
        } else {
            model.manualBrowserSelectedPaths = [entry.id]
            model.manualBrowserAnchorPath = entry.id
        }
    }

    private func selectAllVisibleFiles(in allVisible: [FlattenedNode]) {
        let files = allVisible.filter { !$0.entry.isDirectory }
        if !files.isEmpty {
            model.manualBrowserSelectedPaths = Set(files.map(\.id))
            model.manualBrowserAnchorPath = files.first?.id
        } else {
            model.manualBrowserSelectedPaths = Set(allVisible.map(\.id))
            model.manualBrowserAnchorPath = allVisible.first?.id
        }
    }

    private func targetURLsForAction(clicked: FileBrowserEntry, allVisible: [FlattenedNode]) -> [URL] {
        if model.manualBrowserSelectedPaths.contains(clicked.id) {
            let ordered = allVisible
                .filter { model.manualBrowserSelectedPaths.contains($0.id) }
                .map(\.entry.url)
            if !ordered.isEmpty {
                return ordered
            }
        }
        return [clicked.url]
    }

    private func makeBrowserDragProvider(for entry: FileBrowserEntry, allVisible: [FlattenedNode]) -> NSItemProvider {
        let urls = targetURLsForAction(clicked: entry, allVisible: allVisible)
        let payload = ManualDragTransfer(
            kind: .browserFiles,
            filePaths: urls.map(\.path),
            sourceColumn: nil,
            cellIDs: [],
            sourceIndex: nil
        )
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.json.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}

// MARK: - Pairing Cell View (Filled, Blank Alignment Slot, or Shorter-Column Empty Slot)

private struct ManualPairingCellView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    let column: ManualBatchColumnKind
    let rowIndex: Int
    let cell: ManualBatchCell?
    let job: EpisodeJob?
    let rowHeight: CGFloat
    let isSelectedCell: Bool
    let onSelectCell: () -> Void
    let onDropPayload: ([NSItemProvider]) -> Bool
    let onDragProvider: (ManualBatchCell) -> NSItemProvider
    let dragBadgeCount: (ManualBatchCell) -> Int

    @State private var isDropTargeted = false
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
        .overlay(alignment: .top) {
            if isDropTargeted {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(height: 2)
            }
        }
        .background(isDropTargeted ? Palette.accent.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelectCell)
        .onHover { isHovered = $0 }
        .onDrop(of: [.json, .fileURL], isTargeted: $isDropTargeted, perform: onDropPayload)
    }

    private func filledCellView(cell: ManualBatchCell, url: URL) -> some View {
        let colCount = model.manualColumns.cells(in: column).count

        return HStack(spacing: Space.xs) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(isHovered ? .secondary : .tertiary)
                .frame(width: 12)

            Text(url.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)

            Spacer(minLength: 2)

            if isHovered && !model.isRunning {
                Button {
                    model.manualRemoveCell(in: column, at: rowIndex, undoManager: undoManager)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this item from \(column.title)")
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isSelectedCell {
                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 1)
                    .padding(2)
            }
        }
        .onDrag {
            onDragProvider(cell)
        } preview: {
            DragBadgePreview(count: dragBadgeCount(cell), title: url.lastPathComponent)
        }
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

        return HStack(spacing: Space.xs) {
            Image(systemName: "rectangle.dashed")
                .font(.caption2)
                .foregroundStyle(Surfaces.statusWarning)
            Text("Blank Slot")
                .font(.caption)
                .foregroundStyle(Surfaces.statusWarning)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isHovered && !model.isRunning {
                Button {
                    model.manualRemoveCell(in: column, at: rowIndex, undoManager: undoManager)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove blank alignment slot")
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onDrag {
            onDragProvider(cell)
        } preview: {
            DragBadgePreview(count: 1, title: "Blank Slot")
        }
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

// MARK: - Per-Row Status Indicator

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
            .help(info.help)
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

// MARK: - Empty & Tail Drop Targets

private struct ManualEmptyColumnDropTarget: View {
    let column: ManualBatchColumnKind
    let prompt: String
    let onAdd: () -> Void
    let onDropProviders: ([NSItemProvider]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: column == .sourceSubtitle ? "captions.bubble" : "film")
                .font(.title3)
                .foregroundStyle(isTargeted ? Palette.accent : .secondary)
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add Files…", action: onAdd)
                .controlSize(.mini)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Palette.accent.opacity(0.08) : Surfaces.dropZone)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(
                    isTargeted ? Palette.accent : Surfaces.hairline,
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4])
                )
                .padding(Space.sm)
        )
        .onDrop(of: [.json, .fileURL], isTargeted: $isTargeted, perform: onDropProviders)
    }
}

private struct ManualColumnTailDropZone: View {
    let column: ManualBatchColumnKind
    let onDropProviders: ([NSItemProvider]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            isTargeted ? Palette.accent.opacity(0.08) : Color.clear
            if isTargeted {
                Text("Drop to append to \(column.title)")
                    .font(.caption)
                    .foregroundStyle(Palette.accentText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.json, .fileURL], isTargeted: $isTargeted, perform: onDropProviders)
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

@MainActor
private final class ManualURLDropCollector {
    private var remaining: Int
    private var urls: [URL] = []
    private let completion: ([URL]) -> Void

    init(total: Int, completion: @escaping ([URL]) -> Void) {
        self.remaining = total
        self.completion = completion
    }

    func record(_ url: URL?) {
        if let url { urls.append(url) }
        remaining -= 1
        if remaining <= 0, !urls.isEmpty {
            completion(urls)
        }
    }
}
