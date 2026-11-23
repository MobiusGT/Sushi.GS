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
                        batchPrimaryHeaderBar
                            .gridProbe("batchHeader", area: "batch")

                        batchSecondaryHeaderBar
                            .gridProbe("batchSubHeader", area: "batch")

                        InlineSyncOptionsStrip(includeHQToggle: true, framedAsCard: true)
                            .gridProbe("batchSyncOptions", area: "batch")
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.top, model.dependencies.allRequiredReady ? Space.md : 0)

                    VStack(spacing: 0) {
                        queueListSection
                            .frame(minHeight: 168, maxHeight: 232)
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
            "Clear Batch Queue?",
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

    // MARK: - Stage 1: Two-Folder Intake

    private var batchIntakeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
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
                .gridProbe("intakeTitle", area: "batch-intake")

                HStack(alignment: .top, spacing: Space.lg) {
                    BatchIntakeFolderCard(
                        title: "Source Folder",
                        emptyPrompt: "Drop the folder containing your source videos and subtitles",
                        chooseLabel: "Choose Source Folder…",
                        symbol: "folder.badge.plus",
                        isReady: model.hasStagedSource,
                        folderURL: model.batchSourceFolder,
                        mediaCount: model.stagedSourceMedia.count,
                        subtitleCount: model.stagedSourceSubtitles.count,
                        isTargeted: $isDropSourceTargeted,
                        onChoose: { model.pickBatchSourceFolder(replaceExisting: true) },
                        onDrop: { urls in model.stageBatchInput(urls, asSource: true, replaceExisting: true) },
                        onClear: { model.clearBatchSourceIntake() }
                    )

                    BatchIntakeFolderCard(
                        title: "Target Folder",
                        emptyPrompt: "Drop the folder containing the target videos to sync to",
                        chooseLabel: "Choose Target Folder…",
                        symbol: "sparkles.tv",
                        isReady: model.hasStagedTarget,
                        folderURL: model.batchTargetFolder,
                        mediaCount: model.stagedTargetMedia.count,
                        subtitleCount: 0,
                        isTargeted: $isDropTargetTargeted,
                        onChoose: { model.pickBatchTargetFolder(replaceExisting: true) },
                        onDrop: { urls in model.stageBatchInput(urls, asSource: false, replaceExisting: true) },
                        onClear: { model.clearBatchTargetIntake() }
                    )
                }
                .gridProbe("intakeCards", area: "batch-intake")

                HStack(spacing: Space.md) {
                    Button("Add Empty Row", systemImage: "plus") {
                        model.addEmptyBatchRow()
                    }
                    .controlSize(.small)
                    .hoverDescription("Open the pairing table with a blank episode row to assign files manually")

                    if model.hasStagedSource || model.hasStagedTarget {
                        Button("Start Over", systemImage: "arrow.counterclockwise") {
                            model.clearBatchQueue()
                        }
                        .controlSize(.small)
                        .hoverDescription("Clear staged folders and reset Batch Queue intake")
                    }

                    Spacer()

                    if model.hasStagedSource != model.hasStagedTarget {
                        Label(
                            model.hasStagedSource ? "Waiting for Target folder…" : "Waiting for Source folder…",
                            systemImage: "clock"
                        )
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
        if model.hasStagedSource && !model.hasStagedTarget {
            return "Source Ready — Add Target Folder"
        }
        if !model.hasStagedSource && model.hasStagedTarget {
            return "Target Ready — Add Source Folder"
        }
        return "Drop Source & Target Folders"
    }

    private var intakeSubheadline: String {
        if model.hasStagedSource && !model.hasStagedTarget {
            return "Now drop or choose your Target folder. Episodes will pair automatically once both folders are ready."
        }
        if !model.hasStagedSource && model.hasStagedTarget {
            return "Now drop or choose your Source folder. Episodes will pair automatically once both folders are ready."
        }
        return "Add both folders to pair episodes automatically. Exact filename matches are auto-verified; regex matches wait for quick verification."
    }

    // MARK: - Stage 2: Queue Header Bars

    private var batchPrimaryHeaderBar: some View {
        HStack(spacing: Space.sm) {
            Button("Add Source Folder", systemImage: "folder.badge.plus") {
                model.pickBatchSourceFolder(replaceExisting: false)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isRunning)
            .hoverDescription("Choose a Source folder to append and re-pair episodes (Option-Command-O)")

            Button("Add Target Folder", systemImage: "sparkles.tv") {
                model.pickBatchTargetFolder(replaceExisting: false)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isRunning)
            .hoverDescription("Choose a Target folder to append and re-pair episodes (Option-Shift-Command-O)")

            Spacer(minLength: Space.sm)

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
                .hoverDescription("Clear all queued episodes and return to empty two-folder intake")

                Button {
                    model.startBatchQueue()
                } label: {
                    Label("Start Batch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .disabled(!model.dependencies.allRequiredReady || !model.batchJobs.contains(where: \.hasRequiredInputs))
                .hoverDescription("Start processing queued episodes (Command-R)")
            }
        }
    }

    private var batchSecondaryHeaderBar: some View {
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
            } else if !model.batchJobs.isEmpty {
                Label("All Pairs Verified", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Surfaces.statusSuccess)
                    .hoverDescription("Every paired episode in this batch has been verified")
            }

            Spacer(minLength: Space.sm)

            Button("Rules…", systemImage: "slider.horizontal.3") {
                showTrackRulesPopover.toggle()
            }
            .controlSize(.small)
            .fixedSize()
            .popover(isPresented: $showTrackRulesPopover, arrowEdge: .bottom) {
                BatchTrackRulesPopover()
                    .environment(model)
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
            .hoverDescription("Presets, add row, retry flagged, and manual merge actions")
        }
    }

    // MARK: - Stage 2: Queue List & Selected Editor

    private var queueListSection: some View {
        @Bindable var model = model
        return List(selection: $model.selectedBatchJobIDs) {
            ForEach(model.batchJobs) { job in
                BatchJobRow(
                    job: job,
                    onToggleVerify: { model.toggleVerification(for: job) }
                )
                .tag(job.id)
                .contextMenu {
                    if job.sourceURL != nil && job.targetURL != nil {
                        Button(job.isVerified ? "Mark Pair Unverified" : "Verify Pair") {
                            model.toggleVerification(for: job)
                        }
                        Divider()
                    }
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
                    Button("Remove from Queue", role: .destructive) {
                        let targets = model.selectedBatchJobIDs.contains(job.id)
                            ? model.selectedBatchJobIDs
                            : [job.id]
                        model.removeBatchJobs(ids: targets, undoManager: undoManager)
                    }
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
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text("\(job.episodeBadge) · Pairing & Track Overrides")
                            .font(.headline)

                        if job.sourceURL != nil && job.targetURL != nil {
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
                                .hoverDescription("Confirm this Source → Target pairing is correct")
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
                            Text("Source File").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            HStack(spacing: Space.sm) {
                                Text(job.sourceURL?.lastPathComponent ?? "Not assigned")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(job.sourceURL == nil ? .secondary : .primary)
                                    .help(job.sourceURL?.path ?? "")
                                Spacer()
                                Button("Choose…") {
                                    if let url = model.pickSingleFile(title: "Choose Source Media", allowedExtensions: Array(EpisodePairing.mediaExtensions)) {
                                        job.sourceURL = url
                                        if job.targetURL != nil {
                                            model.markVerified(job)
                                        }
                                        Task { await model.probeBatchJob(job) }
                                    }
                                }
                                .controlSize(.small)
                            }
                        }

                        GridRow {
                            Text("Target File").foregroundStyle(.secondary)
                            HStack(spacing: Space.sm) {
                                Text(job.targetURL?.lastPathComponent ?? "Not assigned")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(job.targetURL == nil ? .secondary : .primary)
                                    .help(job.targetURL?.path ?? "")
                                Spacer()
                                Button("Choose…") {
                                    if let url = model.pickSingleFile(title: "Choose Target Media", allowedExtensions: Array(EpisodePairing.mediaExtensions)) {
                                        job.targetURL = url
                                        model.markVerified(job)
                                        Task { await model.probeBatchJob(job) }
                                    }
                                }
                                .controlSize(.small)
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
                            if let url = model.pickSingleFile(title: "Choose External Subtitle", allowedExtensions: Array(EpisodePairing.subtitleExtensions)) {
                                job.externalSubtitleURL = url
                                job.useExternalSubtitle = true
                                job.hasCustomTrackOverrides = true
                            }
                        },
                        onClearExternalSub: {
                            job.externalSubtitleURL = nil
                            job.useExternalSubtitle = false
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
    let mediaCount: Int
    let subtitleCount: Int
    @Binding var isTargeted: Bool
    let onChoose: () -> Void
    let onDrop: @MainActor ([URL]) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                if isReady {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Surfaces.statusSuccess)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 2)
                        .background(Surfaces.statusSuccess.opacity(0.14), in: Capsule())
                }
            }

            if isReady {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(folderURL?.lastPathComponent ?? "Selected Media Files")
                        .font(.title3.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(folderURL?.path ?? "")

                    HStack(spacing: Space.md) {
                        Label(
                            "\(mediaCount) \(mediaCount == 1 ? "media file" : "media files")",
                            systemImage: "film"
                        )
                        .foregroundStyle(mediaCount > 0 ? .secondary : Surfaces.statusWarning)

                        if subtitleCount > 0 {
                            Label(
                                "\(subtitleCount) \(subtitleCount == 1 ? "subtitle" : "subtitles")",
                                systemImage: "captions.bubble"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)

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
                    Spacer()
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
        .padding(Space.lg)
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

// MARK: - Stage 2 Queue Row with Fast 1-Click Verification

private struct BatchJobRow: View {
    let job: EpisodeJob
    let onToggleVerify: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Text(job.episodeBadge)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(job.sourceURL?.lastPathComponent ?? "Missing Source")
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(job.sourceURL == nil ? Surfaces.statusError : .primary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(job.targetURL?.lastPathComponent ?? "Missing Target")
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(job.targetURL == nil ? Surfaces.statusError : .primary)
                }

                HStack(spacing: Space.md) {
                    if let srcA = job.selectedSourceAudioTrack, let dstA = job.selectedTargetAudioTrack {
                        Text("Audio: T\(srcA.id) (\(srcA.lang)) → T\(dstA.id) (\(dstA.lang))")
                    }
                    if job.useExternalSubtitle, let ext = job.externalSubtitleURL {
                        Text("Sub: \(ext.lastPathComponent)")
                    } else if !job.selectedEmbeddedSubtitles.isEmpty {
                        let ids = job.selectedEmbeddedSubtitles.map { "T\($0.id)" }.joined(separator: ", ")
                        Text("Sub: \(ids)")
                    }
                    if job.hasCustomTrackOverrides {
                        Text("Custom Override")
                            .foregroundStyle(Palette.accentText)
                    }
                    if job.isAutoVerifiedExactMatch && job.isVerified {
                        Text("Exact Name")
                            .foregroundStyle(Surfaces.statusSuccess)
                    } else if !job.isVerified && job.sourceURL != nil && job.targetURL != nil {
                        Text("Unverified")
                            .foregroundStyle(Surfaces.statusWarning)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: Space.sm)

            if job.sourceURL != nil && job.targetURL != nil {
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

            JobStatusBadge(status: job.status)
        }
        .padding(.vertical, Space.xs)
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
            .hoverDescription("Unverified regex match — click to confirm this Source → Target pairing")
        }
    }
}

private struct BatchTrackRulesPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Batch Track Rules")
                .font(.headline)
            Text("Choose how audio and subtitle tracks are matched across all episodes. Individual episodes can still override these rules.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ruleEditor(title: "Source Audio", rule: $model.batchSrcAudioRule)
            Divider()
            ruleEditor(title: "Target Audio", rule: $model.batchDstAudioRule)
            Divider()
            ruleEditor(title: "Source Subtitle", rule: $model.batchSubRule)

            HStack {
                Spacer()
                Button("Apply Rules to All Episodes") {
                    model.applyBatchTrackRulesToAll()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Space.lg)
        .frame(width: 380)
    }

    private func ruleEditor(title: String, rule: Binding<BatchTrackRule>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.callout.weight(.medium))
            Picker("Rule", selection: rule.mode) {
                ForEach(BatchTrackRule.MatchMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()

            switch rule.wrappedValue.mode {
            case .firstOrDefault:
                EmptyView()
            case .trackPosition:
                Stepper("Track #\(rule.wrappedValue.trackPosition)", value: rule.trackPosition, in: 1...16)
                    .font(.callout)
            case .streamID:
                Stepper("Stream ID \(rule.wrappedValue.streamID)", value: rule.streamID, in: 0...32)
                    .font(.callout)
            case .languageAndTitle:
                HStack(spacing: Space.sm) {
                    TextField("Language (e.g. jpn, eng)", text: rule.languageFilter)
                        .textFieldStyle(.roundedBorder)
                    TextField("Title contains…", text: rule.titleContains)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }
}
