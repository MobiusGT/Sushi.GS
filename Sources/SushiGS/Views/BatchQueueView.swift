import AppKit
import SwiftUI
import SushiGSKit
import UniformTypeIdentifiers

struct BatchQueueView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    @State private var showTrackRulesPopover = false
    @State private var isDropSourceTargeted = false
    @State private var isDropTargetTargeted = false
    @State private var isDropSubtitleTargeted = false

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

            if !model.isBatchInQueueStage {
                batchIntakeView
                    .gridArea("batch-intake", inset: Space.margin)
            } else {
                VStack(alignment: .leading, spacing: Space.md) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        batchFolderActionBar
                            .gridProbe("batchHeader", area: "batch")

                        batchTransportHeaderBar
                            .gridProbe("batchSubHeader", area: "batch")

                        InlineSyncOptionsStrip(includeHQToggle: true, framedAsCard: true)
                            .gridProbe("batchSyncOptions", area: "batch")
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.top, model.dependencies.allRequiredReady ? Space.md : 0)

                    VStack(spacing: 0) {
                        queueListSection
                            .frame(minHeight: 168, maxHeight: 256)
                        Divider()
                        selectedEpisodeEditor
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .gridArea("batch", inset: Space.margin)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Clear Auto Batch?",
            isPresented: $model.showClearBatchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Queue", role: .destructive) {
                model.clearBatchQueue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Queued episodes and pairings will be cleared, returning to folder intake. Your media files on disk will not be modified.")
        }
    }

    // MARK: - Stage 1: Folder Intake (Embedded 2-Folder / External 3-Folder)

    private var batchIntakeView: some View {
        @Bindable var model = model
        let isExternal = model.batchSubtitleMode == .external

        return ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(alignment: .top, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.title2)
                                .foregroundStyle(Palette.accent)
                            Text(intakeHeadline)
                                .font(.title2.weight(.semibold))
                        }
                        Text(intakeSubheadline)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: Space.sm)

                    HStack(spacing: Space.sm) {
                        Text("Subtitles")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Picker("Subtitle Mode", selection: $model.batchSubtitleMode) {
                            Text("Embedded")
                                .tag(BatchSubtitleMode.embedded)
                                .help(SushiHelpText.embeddedSubtitlesMode)
                            Text("External")
                                .tag(BatchSubtitleMode.external)
                                .help(SushiHelpText.externalSubtitlesMode)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 176)
                        .hoverDescription(SushiHelpText.subtitleModeSwitch)
                    }
                    .hoverDescription(SushiHelpText.subtitleModeSwitch)
                }
                .gridProbe("intakeTitle", area: "batch-intake")

                HStack(alignment: .top, spacing: isExternal ? Space.md : Space.lg) {
                    BatchIntakeFolderCard(
                        title: "Source Media Folder",
                        emptyPrompt: isExternal
                            ? "Drop the folder with your source videos"
                            : "Drop the folder with your source videos and embedded subtitles",
                        chooseLabel: "Choose Folder…",
                        symbol: "folder.badge.plus",
                        isReady: model.hasStagedSource,
                        folderURL: model.batchSourceFolder,
                        itemCount: model.stagedSourceMedia.count,
                        itemUnitSingular: "media file",
                        itemUnitPlural: "media files",
                        itemCountSymbol: "film",
                        compactHeader: isExternal,
                        isTargeted: $isDropSourceTargeted,
                        onChoose: { model.pickBatchSourceFolder(replaceExisting: true) },
                        onDrop: { urls in model.stageBatchInput(urls, slot: .sourceMedia, replaceExisting: true) },
                        onClear: { model.clearBatchSourceIntake() }
                    )

                    BatchIntakeFolderCard(
                        title: "Target Media Folder",
                        emptyPrompt: "Drop the folder with the target videos to sync to",
                        chooseLabel: "Choose Folder…",
                        symbol: "sparkles.tv",
                        isReady: model.hasStagedTarget,
                        folderURL: model.batchTargetFolder,
                        itemCount: model.stagedTargetMedia.count,
                        itemUnitSingular: "media file",
                        itemUnitPlural: "media files",
                        itemCountSymbol: "film",
                        compactHeader: isExternal,
                        isTargeted: $isDropTargetTargeted,
                        onChoose: { model.pickBatchTargetFolder(replaceExisting: true) },
                        onDrop: { urls in model.stageBatchInput(urls, slot: .targetMedia, replaceExisting: true) },
                        onClear: { model.clearBatchTargetIntake() }
                    )

                    if isExternal {
                        BatchIntakeFolderCard(
                            title: "Subtitle Folder",
                            emptyPrompt: "Drop a folder or .ass, .srt, .ssa files to pair",
                            chooseLabel: "Choose Folder…",
                            symbol: "captions.bubble",
                            isReady: model.hasStagedExternalSubtitles,
                            folderURL: model.batchSubtitleFolder,
                            itemCount: model.stagedExternalSubtitles.count,
                            itemUnitSingular: "subtitle file",
                            itemUnitPlural: "subtitle files",
                            itemCountSymbol: "captions.bubble",
                            compactHeader: true,
                            isTargeted: $isDropSubtitleTargeted,
                            onChoose: { model.pickBatchSubtitleFolder(replaceExisting: true) },
                            onDrop: { urls in model.stageBatchInput(urls, slot: .externalSubtitles, replaceExisting: true) },
                            onClear: { model.clearBatchSubtitleIntake() }
                        )
                    }
                }
                .gridProbe("intakeCards", area: "batch-intake")

                HStack(spacing: Space.md) {
                    if model.hasAnyStagedBatchFolder {
                        Button {
                            model.continueToAutoBatchQueue()
                        } label: {
                            Label("Continue to Queue", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .hoverDescription("Open the pairing queue now with the files from your staged folder(s)")
                    } else {
                        Button("Continue to Queue", systemImage: "arrow.right.circle") {
                            model.continueToAutoBatchQueue()
                        }
                        .controlSize(.small)
                        .hoverDescription("Open the pairing queue with a blank editable row, or populate from any staged folders")
                    }

                    if model.hasAnyStagedBatchFolder {
                        Button("Start Over", systemImage: "arrow.counterclockwise") {
                            model.clearBatchQueue()
                        }
                        .controlSize(.small)
                        .hoverDescription("Clear staged folders and reset Auto Batch intake")
                    }

                    Spacer()

                    if let waitingText = intakeWaitingStatus {
                        Label(waitingText, systemImage: "clock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .gridProbe("intakeFooter", area: "batch-intake")
            }
            .padding(Space.margin)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var intakeHeadline: String {
        let progress = model.stagedFolderProgress
        if progress.ready == 0 {
            return model.batchSubtitleMode == .external
                ? "Drop Source, Target & Subtitle Folders"
                : "Drop Source & Target Media Folders"
        }
        let missing = missingIntakeFolderNames
        if missing.count == 1 {
            return "\(progress.ready) of \(progress.total) Ready — Add \(missing[0])"
        }
        return "\(progress.ready) of \(progress.total) Ready — Add Remaining Folders"
    }

    private var intakeSubheadline: String {
        if model.batchSubtitleMode == .external {
            return "Add all three folders to auto-pair Source, Target, and external subtitles, or click Continue to Queue with partial folders."
        }
        return "Add both media folders to pair episodes automatically. Exact filename matches auto-verify; heuristic matches wait for quick verification."
    }

    private var missingIntakeFolderNames: [String] {
        var names: [String] = []
        if !model.hasStagedSource { names.append("Source Media Folder") }
        if !model.hasStagedTarget { names.append("Target Media Folder") }
        if model.batchSubtitleMode == .external && !model.hasStagedExternalSubtitles {
            names.append("Subtitle Folder")
        }
        return names
    }

    private var intakeWaitingStatus: String? {
        let progress = model.stagedFolderProgress
        guard progress.ready > 0, progress.ready < progress.total else { return nil }
        let missing = missingIntakeFolderNames
        if missing.count == 1 {
            return "Waiting for \(missing[0])…"
        }
        return "Waiting for \(missing.joined(separator: " & "))…"
    }

    // MARK: - Stage 2: Queue Header Bars

    private var batchFolderActionBar: some View {
        HStack(spacing: Space.sm) {
            Button("Add Source Media Folder", systemImage: "folder.badge.plus") {
                model.pickBatchSourceFolder(replaceExisting: false)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isRunning)
            .hoverDescription("Choose a Source Media Folder to append and re-pair episodes (Option-Command-O)")

            Button("Add Target Media Folder", systemImage: "sparkles.tv") {
                model.pickBatchTargetFolder(replaceExisting: false)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isRunning)
            .hoverDescription("Choose a Target Media Folder to append and re-pair episodes (Option-Shift-Command-O)")

            Button("Add External Subtitle Folder", systemImage: "captions.bubble") {
                model.pickBatchSubtitleFolder(replaceExisting: false)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isRunning)
            .hoverDescription("Choose an External Subtitle Folder, switch to External mode if needed, and pair subtitles (Control-Option-Command-O)")

            Spacer(minLength: Space.xs)
        }
    }

    private var batchTransportHeaderBar: some View {
        @Bindable var model = model
        return HStack(spacing: Space.sm) {
            if model.unverifiedBatchCount > 0 {
                Button {
                    model.verifyAllBatchPairs()
                } label: {
                    Label("Verify All (\(model.unverifiedBatchCount))", systemImage: "checkmark.circle")
                }
                .controlSize(.small)
                .fixedSize()
                .hoverDescription("Confirm all \(model.unverifiedBatchCount) remaining unverified pairs are matched correctly")
            } else if !model.batchJobs.isEmpty && model.batchJobs.contains(where: { $0.isComplete(for: model.batchSubtitleMode) }) {
                Label("All Pairs Verified", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Surfaces.statusSuccess)
                    .hoverDescription("Every complete episode pair in this batch has been verified")
            }

            if model.batchSubtitleMode == .external {
                Label("External Subs", systemImage: "captions.bubble")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.accentText)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(Palette.accent.opacity(0.14), in: Capsule())
                    .hoverDescription("Auto Batch is pairing external .ass, .srt, and .ssa subtitle files")
            }

            Spacer(minLength: Space.sm)

            Button("Rules…", systemImage: "slider.horizontal.3") {
                showTrackRulesPopover.toggle()
            }
            .controlSize(.small)
            .fixedSize()
            .popover(isPresented: $showTrackRulesPopover, arrowEdge: .bottom) {
                BatchTrackRulesPopover(
                    srcAudioRule: $model.batchSrcAudioRule,
                    dstAudioRule: $model.batchDstAudioRule,
                    subRule: $model.batchSubRule,
                    showSubtitleRule: model.batchSubtitleMode == .embedded,
                    onApply: { model.applyBatchTrackRulesToAll() }
                )
            }
            .hoverDescription("Configure batch-wide audio and subtitle track selection rules")

            Menu {
                Section("Apply Preset") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.applyPreset(preset) }
                    }
                }
                Divider()
                Button("Add Empty Row") { model.addEmptyBatchRow() }
                if model.batchJobs.contains(where: { $0.status == .failed || $0.status == .warned || $0.status == .cancelled }) {
                    Button("Retry Flagged") { model.retryFailedOrWarned() }
                }
                if model.batchJobs.contains(where: \.canMergeManually) && model.dependencies.isInstalled(.mkvmerge) {
                    Button("Merge Ready MKVs") { model.mergeCompletedJobs() }
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .controlSize(.small)
            .fixedSize()
            .hoverDescription("Presets, add empty row, retry flagged, and manual merge actions")

            if model.isRunning {
                Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                    model.togglePauseQueue()
                }
                .controlSize(.small)
                .fixedSize()
                .hoverDescription("Pause or resume after the current episode finishes (Option-Command-P)")

                Button(model.isCancelling ? "Cancelling…" : "Cancel", role: .destructive) {
                    model.cancelActiveJob()
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(model.isCancelling)
                .hoverDescription("Cancel the active episode and delete its temporary and partial files (Command-Period)")
            } else {
                Button("Clear Queue") {
                    model.requestClearBatchQueue()
                }
                .controlSize(.small)
                .fixedSize()
                .hoverDescription("Clear all queued episodes and return to folder intake")

                Button {
                    model.startBatchQueue()
                } label: {
                    Label("Start Batch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .disabled(!model.dependencies.allRequiredReady || !model.batchJobs.contains(where: \.hasPairedFiles))
                .hoverDescription("Start processing queued episodes (Command-R)")
            }
        }
    }

    // MARK: - Stage 2: Queue List & Selected Editor

    private var queueListSection: some View {
        @Bindable var model = model
        let externalMode = model.batchSubtitleMode == .external

        return List(selection: $model.selectedBatchJobIDs) {
            ForEach(model.batchJobs) { job in
                BatchJobRow(
                    job: job,
                    isExternalMode: externalMode,
                    onToggleVerify: { model.toggleVerification(for: job) },
                    onReselectSource: { model.reselectBatchSource(for: job) },
                    onReselectTarget: { model.reselectBatchTarget(for: job) },
                    onReselectSubtitle: { model.reselectBatchSubtitle(for: job) },
                    onRemoveSource: { model.removeBatchSource(for: job) },
                    onRemoveTarget: { model.removeBatchTarget(for: job) },
                    onRemoveSubtitle: { model.removeBatchSubtitle(for: job) },
                    onRemoveRow: { model.removeBatchJob(job, undoManager: undoManager) }
                )
                .tag(job.id)
                .contextMenu {
                    if job.isComplete(for: model.batchSubtitleMode) {
                        Button(job.isVerified ? "Mark Pair Unverified" : "Verify Pair") {
                            model.toggleVerification(for: job)
                        }
                        Divider()
                    }
                    Button(job.sourceURL == nil ? "Choose Source Media File…" : "Reselect Source Media File…") {
                        model.reselectBatchSource(for: job)
                    }
                    .disabled(job.status == .running)
                    Button(job.targetURL == nil ? "Choose Target Media File…" : "Reselect Target Media File…") {
                        model.reselectBatchTarget(for: job)
                    }
                    .disabled(job.status == .running)
                    if externalMode || job.useExternalSubtitle {
                        Button(job.externalSubtitleURL == nil ? "Choose External Subtitle…" : "Reselect External Subtitle…") {
                            model.reselectBatchSubtitle(for: job)
                        }
                        .disabled(job.status == .running)
                    }
                    if job.sourceURL != nil {
                        Button("Remove Source Media File") {
                            model.removeBatchSource(for: job)
                        }
                        .disabled(job.status == .running)
                    }
                    if job.targetURL != nil {
                        Button("Remove Target Media File") {
                            model.removeBatchTarget(for: job)
                        }
                        .disabled(job.status == .running)
                    }
                    if job.externalSubtitleURL != nil {
                        Button("Remove External Subtitle") {
                            model.removeBatchSubtitle(for: job)
                        }
                        .disabled(job.status == .running)
                    }
                    Divider()
                    if job.status == .failed || job.status == .warned || job.status == .cancelled {
                        Button("Retry Episode") {
                            job.resetForRetry()
                            model.startBatchQueue()
                        }
                    }
                    if job.canMergeManually && model.dependencies.isInstalled(.mkvmerge) {
                        Button("Merge MKV") {
                            model.selectedBatchJobIDs = [job.id]
                            model.mergeCompletedJobs()
                        }
                    }
                    if let firstWarn = job.warnings.first {
                        Button("Jump to Warning in Log") {
                            model.selectedBatchJobIDs = [job.id]
                            model.jumpToWarning(firstWarn, in: job)
                        }
                    }
                    if let output = job.mergedFilepath ?? job.syncedFiles.first {
                        Button("Reveal Output in Finder") {
                            model.revealInFinder(output)
                        }
                    }
                    Divider()
                    Button("Remove Row", role: .destructive) {
                        let targets = model.selectedBatchJobIDs.contains(job.id)
                            ? model.selectedBatchJobIDs
                            : [job.id]
                        model.removeBatchJobs(ids: targets, undoManager: undoManager)
                    }
                    .disabled(job.status == .running)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand {
            guard !model.selectedBatchJobIDs.isEmpty else { return }
            model.removeBatchJobs(ids: model.selectedBatchJobIDs, undoManager: undoManager)
        }
    }

    @ViewBuilder
    private var selectedEpisodeEditor: some View {
        if let job = selectedBatchJob {
            let showExternalRow = model.batchSubtitleMode == .external || job.useExternalSubtitle
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text("\(job.episodeBadge) · Pairing & Track Overrides")
                            .font(.headline)

                        if job.isComplete(for: model.batchSubtitleMode) {
                            if job.isVerified {
                                Button {
                                    model.toggleVerification(for: job)
                                } label: {
                                    Label(
                                        job.isAutoVerifiedExactMatch ? "Verified (Exact)" : "Verified",
                                        systemImage: "checkmark.circle.fill"
                                    )
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Surfaces.statusSuccess)
                                }
                                .buttonStyle(.plain)
                                .hoverDescription(
                                    job.isAutoVerifiedExactMatch
                                        ? "Auto-verified exact filename match — click to mark unverified"
                                        : "Verified pairing — click to mark unverified"
                                )
                            } else {
                                Label("Unverified Pair", systemImage: "exclamationmark.circle")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Surfaces.statusWarning)
                                Button("Verify Pair") {
                                    model.markVerified(job)
                                }
                                .controlSize(.small)
                                .hoverDescription("Confirm this episode pairing is correct")
                            }
                        }

                        Spacer()
                        JobStatusBadge(status: job.status)
                    }

                    WarningBannerView(job: job) { warning in
                        model.jumpToWarning(warning, in: job)
                    }

                    if let err = job.errorMessage {
                        ErrorBannerView(message: err) {
                            model.showInspector = true
                            model.logScope = .selectedJob
                        }
                    }

                    // Manual file pairing editor
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
                        GridRow {
                            Text("Source Media").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            HStack(spacing: Space.sm) {
                                Text(job.sourceURL?.lastPathComponent ?? "No match found")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(job.sourceURL == nil ? Surfaces.statusWarning : .primary)
                                    .help(job.sourceURL?.path ?? "No matching Source media file was found")
                                Spacer()
                                if job.sourceURL != nil {
                                    Button("Remove") {
                                        model.removeBatchSource(for: job)
                                    }
                                    .controlSize(.small)
                                    .disabled(job.status == .running)
                                    .hoverDescription("Clear the Source media file from this row")
                                }
                                Button(job.sourceURL == nil ? "Choose File…" : "Reselect…") {
                                    model.reselectBatchSource(for: job)
                                }
                                .controlSize(.small)
                                .disabled(job.status == .running)
                                .hoverDescription("Choose a Source file starting in the selected Source Media Folder")
                            }
                        }

                        GridRow {
                            Text("Target Media").foregroundStyle(.secondary)
                            HStack(spacing: Space.sm) {
                                Text(job.targetURL?.lastPathComponent ?? "No match found")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(job.targetURL == nil ? Surfaces.statusWarning : .primary)
                                    .help(job.targetURL?.path ?? "No matching Target media file was found")
                                Spacer()
                                if job.targetURL != nil {
                                    Button("Remove") {
                                        model.removeBatchTarget(for: job)
                                    }
                                    .controlSize(.small)
                                    .disabled(job.status == .running)
                                    .hoverDescription("Clear the Target media file from this row")
                                }
                                Button(job.targetURL == nil ? "Choose File…" : "Reselect…") {
                                    model.reselectBatchTarget(for: job)
                                }
                                .controlSize(.small)
                                .disabled(job.status == .running)
                                .hoverDescription("Choose a Target file starting in the selected Target Media Folder")
                            }
                        }

                        if showExternalRow {
                            GridRow {
                                Text("External Subtitle").foregroundStyle(.secondary)
                                HStack(spacing: Space.sm) {
                                    Text(job.externalSubtitleURL?.lastPathComponent ?? "No match found")
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(job.externalSubtitleURL == nil ? Surfaces.statusWarning : .primary)
                                        .help(job.externalSubtitleURL?.path ?? "No matching External Subtitle file was found")
                                    Spacer()
                                    if job.externalSubtitleURL != nil {
                                        Button("Remove") {
                                            model.removeBatchSubtitle(for: job)
                                        }
                                        .controlSize(.small)
                                        .disabled(job.status == .running)
                                        .hoverDescription("Remove the External Subtitle from this row")
                                    }
                                    Button(job.externalSubtitleURL == nil ? "Choose Subtitle…" : "Reselect…") {
                                        model.reselectBatchSubtitle(for: job)
                                    }
                                    .controlSize(.small)
                                    .disabled(job.status == .running)
                                    .hoverDescription("Choose an External Subtitle starting in the selected Subtitle Folder")
                                }
                            }
                        }
                    }
                    .padding(Space.md)
                    .background(Surfaces.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder(Surfaces.hairline, lineWidth: 1)
                    )

                    TrackSelectionCard(
                        job: job,
                        markAsCustomOverride: true,
                        onChooseExternalSub: {
                            model.reselectBatchSubtitle(for: job)
                            job.hasCustomTrackOverrides = true
                        },
                        onClearExternalSub: {
                            model.removeBatchSubtitle(for: job)
                            job.hasCustomTrackOverrides = true
                        },
                        onResetToBatchRule: {
                            job.applyBatchRules(
                                srcAudio: model.batchSrcAudioRule,
                                dstAudio: model.batchDstAudioRule,
                                subRule: model.batchSubRule,
                                force: true
                            )
                        }
                    )

                    if !job.syncedFiles.isEmpty || job.mergedFilepath != nil {
                        HStack(spacing: Space.md) {
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
                .padding(Space.margin)
            }
        } else {
            ContentUnavailableView(
                "Select an Episode",
                systemImage: "list.bullet.rectangle",
                description: Text("Select a row above to inspect warnings, adjust file pairings, or override audio and subtitle tracks.")
            )
        }
    }

    private var selectedBatchJob: EpisodeJob? {
        guard let first = model.selectedBatchJobIDs.first else { return nil }
        return model.batchJobs.first(where: { $0.id == first })
    }
}

// MARK: - Stage 1 Intake Folder Card

private struct BatchIntakeFolderCard: View {
    let title: String
    let emptyPrompt: String
    let chooseLabel: String
    let symbol: String
    let isReady: Bool
    let folderURL: URL?
    let itemCount: Int
    let itemUnitSingular: String
    let itemUnitPlural: String
    let itemCountSymbol: String
    let compactHeader: Bool
    @Binding var isTargeted: Bool
    let onChoose: () -> Void
    let onDrop: @MainActor ([URL]) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Label(title, systemImage: symbol)
                    .font(compactHeader ? .callout.weight(.semibold) : .headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Space.xs)
                if isReady && !compactHeader {
                    readyBadge
                }
            }

            if isReady {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(folderURL?.lastPathComponent ?? "Selected Files")
                        .font(compactHeader ? .headline : .title3.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(folderURL?.path ?? "")

                    Label(
                        "\(itemCount) \(itemCount == 1 ? itemUnitSingular : itemUnitPlural)",
                        systemImage: itemCountSymbol
                    )
                    .font(.callout)
                    .foregroundStyle(itemCount > 0 ? .secondary : Surfaces.statusWarning)

                    if let path = folderURL?.deletingLastPathComponent().path {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folderURL?.path ?? "")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)

                HStack(spacing: Space.sm) {
                    Button("Replace…", action: onChoose)
                        .controlSize(.small)
                    Button("Clear", action: onClear)
                        .controlSize(.small)
                    Spacer(minLength: Space.xs)
                    if compactHeader {
                        readyBadge
                    }
                }
            } else {
                VStack(spacing: Space.sm) {
                    Image(systemName: symbol)
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(emptyPrompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(chooseLabel, action: onChoose)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, minHeight: 124)
            }
        }
        .padding(compactHeader ? Space.md : Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            cardFill,
            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(
                    cardBorder,
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isReady ? [] : [6, 4])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadDroppedURLs(from: providers, completion: onDrop)
        }
    }

    private var readyBadge: some View {
        Label("Ready", systemImage: "checkmark.circle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Surfaces.statusSuccess)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 2)
            .background(Surfaces.statusSuccess.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private var cardFill: Color {
        if isTargeted { return Palette.accent.opacity(0.10) }
        if isReady { return Surfaces.statusSuccess.opacity(0.05) }
        return Surfaces.dropZone
    }

    private var cardBorder: Color {
        if isTargeted { return Palette.accent }
        if isReady { return Surfaces.statusSuccess.opacity(0.45) }
        return Surfaces.hairline
    }

    private func loadDroppedURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let valid = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !valid.isEmpty else { return false }
        let collector = URLCollector(total: valid.count, completion: completion)
        for p in valid {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in collector.record(url) }
            }
        }
        return true
    }
}

@MainActor
private final class URLCollector {
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

// MARK: - Stage 2 Queue Row with Fast 1-Click Verification & Row File Controls

private struct BatchJobRow: View {
    let job: EpisodeJob
    let isExternalMode: Bool
    let onToggleVerify: () -> Void
    let onReselectSource: () -> Void
    let onReselectTarget: () -> Void
    let onReselectSubtitle: () -> Void
    let onRemoveSource: () -> Void
    let onRemoveTarget: () -> Void
    let onRemoveSubtitle: () -> Void
    let onRemoveRow: () -> Void

    private var isIncompletePair: Bool {
        job.sourceURL == nil || job.targetURL == nil || (isExternalMode && job.externalSubtitleURL == nil)
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(job.episodeBadge)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    if let src = job.sourceURL {
                        Text(src.lastPathComponent)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                            .help(src.path)
                    } else {
                        missingFileSlot(
                            label: "Choose File…",
                            help: "Choose Source media file from the selected Source Media Folder",
                            action: onReselectSource
                        )
                    }

                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let dst = job.targetURL {
                        Text(dst.lastPathComponent)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                            .help(dst.path)
                    } else {
                        missingFileSlot(
                            label: "Choose File…",
                            help: "Choose Target media file from the selected Target Media Folder",
                            action: onReselectTarget
                        )
                    }
                }

                HStack(spacing: Space.md) {
                    if isExternalMode {
                        if let ext = job.externalSubtitleURL {
                            Label(ext.lastPathComponent, systemImage: "captions.bubble")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(ext.path)
                        } else {
                            HStack(spacing: Space.xs) {
                                Image(systemName: "captions.bubble")
                                    .foregroundStyle(Surfaces.statusWarning)
                                Text("No match found")
                                    .foregroundStyle(Surfaces.statusWarning)
                                Button("Choose File…", action: onReselectSubtitle)
                                    .controlSize(.mini)
                                    .disabled(job.status == .running)
                                    .hoverDescription("Choose External Subtitle from the selected Subtitle Folder")
                            }
                        }
                    } else {
                        if let srcA = job.selectedSourceAudioTrack, let dstA = job.selectedTargetAudioTrack {
                            Text("Audio: T\(srcA.id) (\(srcA.lang)) → T\(dstA.id) (\(dstA.lang))")
                        }
                        if job.useExternalSubtitle, let ext = job.externalSubtitleURL {
                            Text("Sub: \(ext.lastPathComponent)")
                        } else if !job.selectedEmbeddedSubtitles.isEmpty {
                            let ids = job.selectedEmbeddedSubtitles.map { "T\($0.id)" }.joined(separator: ", ")
                            Text("Sub: \(ids)")
                        }
                    }

                    if job.hasCustomTrackOverrides {
                        Text("Custom Override")
                            .foregroundStyle(Palette.accentText)
                    }
                    if !isIncompletePair {
                        if job.isAutoVerifiedExactMatch && job.isVerified {
                            Text("Exact Name")
                                .foregroundStyle(Surfaces.statusSuccess)
                        } else if !job.isVerified {
                            Text(job.matchKind == .titleSimilarity ? "Title Match · Unverified" : "Unverified")
                                .foregroundStyle(Surfaces.statusWarning)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: Space.sm)

            if !isIncompletePair {
                verificationControl
            }

            if job.status == .running {
                ProgressView(value: job.progress)
                    .frame(width: 80)
            } else if let avg = job.metrics?.formattedAverageShift {
                Text(avg)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if job.mergedFilepath != nil {
                Label("MKV", systemImage: "film.stack")
                    .font(.caption)
                    .foregroundStyle(Surfaces.statusSuccess)
            }

            if isIncompletePair && job.status == .pending {
                Label("No match found", systemImage: "questionmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Surfaces.statusWarning)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .background(Surfaces.statusWarning.opacity(0.14), in: Capsule())
            } else {
                JobStatusBadge(status: job.status)
            }

            rowActionMenu

            Button(action: onRemoveRow) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(job.status == .running)
            .hoverDescription("Remove this row from the Auto Batch list")
        }
        .padding(.vertical, Space.xs)
    }

    private func missingFileSlot(label: String, help: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: Space.xs) {
            Text("No match found")
                .font(.body)
                .foregroundStyle(Surfaces.statusWarning)
                .lineLimit(1)
            Button(label, action: action)
                .controlSize(.mini)
                .disabled(job.status == .running)
                .hoverDescription(help)
        }
    }

    private var rowActionMenu: some View {
        Menu {
            Button(job.sourceURL == nil ? "Choose Source Media File…" : "Reselect Source Media File…", action: onReselectSource)
            Button(job.targetURL == nil ? "Choose Target Media File…" : "Reselect Target Media File…", action: onReselectTarget)
            if isExternalMode || job.useExternalSubtitle {
                Button(job.externalSubtitleURL == nil ? "Choose External Subtitle…" : "Reselect External Subtitle…", action: onReselectSubtitle)
            }
            Divider()
            Button("Remove Source Media File", action: onRemoveSource)
                .disabled(job.sourceURL == nil)
            Button("Remove Target Media File", action: onRemoveTarget)
                .disabled(job.targetURL == nil)
            if isExternalMode || job.externalSubtitleURL != nil {
                Button("Remove External Subtitle", action: onRemoveSubtitle)
                    .disabled(job.externalSubtitleURL == nil)
            }
            Divider()
            Button("Remove Row", role: .destructive, action: onRemoveRow)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(job.status == .running)
        .hoverDescription("Reselect or remove Source, Target, or External Subtitle files, or remove this row")
    }

    @ViewBuilder
    private var verificationControl: some View {
        if job.isVerified {
            Button(action: onToggleVerify) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Surfaces.statusSuccess)
            }
            .buttonStyle(.plain)
            .hoverDescription(
                job.isAutoVerifiedExactMatch
                    ? "Verified automatically (exact filename match) — click to mark unverified"
                    : "Verified pair — click to mark unverified"
            )
        } else {
            Button(action: onToggleVerify) {
                Label("Verify", systemImage: "checkmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Surfaces.statusWarning)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(Surfaces.statusWarning.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .hoverDescription("Unverified pairing — click to confirm this episode match")
        }
    }
}
