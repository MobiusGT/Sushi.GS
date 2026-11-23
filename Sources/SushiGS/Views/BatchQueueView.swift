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

        VStack(alignment: .leading, spacing: Space.lg) {
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

            if model.batchJobs.isEmpty {
                emptyBatchView
            } else {
                batchHeaderBar
                    .gridProbe("batchHeader", area: "batch")
                    .padding(.horizontal, Space.margin)
                    .padding(.top, model.dependencies.allRequiredReady ? Space.md : 0)

                VStack(spacing: 0) {
                    queueListSection
                        .frame(minHeight: 168, maxHeight: 240)
                    Divider()
                    selectedEpisodeEditor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .gridArea("batch", inset: Space.margin)
    }

    private var emptyBatchView: some View {
        VStack(spacing: Space.xl) {
            ContentUnavailableView {
                Label("No Episodes Queued", systemImage: "square.stack.3d.up")
            } description: {
                Text("Drop Source and Target folders (or multiple episode files) to pair episodes automatically by episode number.")
            } actions: {
                HStack(spacing: Space.md) {
                    Button("Select Source & Target Folders…") {
                        model.openBatchFoldersWorkflow()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Add Empty Row") {
                        model.addEmptyBatchRow()
                    }
                }
            }

            HStack(spacing: Space.lg) {
                batchDropPill(
                    title: "Drop Source Folder or Files",
                    symbol: "folder.badge.plus",
                    isTargeted: $isDropSourceTargeted,
                    asSource: true
                )
                batchDropPill(
                    title: "Drop Target Folder or Files",
                    symbol: "sparkles.tv",
                    isTargeted: $isDropTargetTargeted,
                    asSource: false
                )
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, Space.margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func batchDropPill(title: String, symbol: String, isTargeted: Binding<Bool>, asSource: Bool) -> some View {
        VStack(spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
        .background(
            isTargeted.wrappedValue ? Palette.accent.opacity(0.10) : Surfaces.dropZone,
            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(
                    isTargeted.wrappedValue ? Palette.accent : Surfaces.hairline,
                    style: StrokeStyle(lineWidth: isTargeted.wrappedValue ? 2 : 1, dash: [6, 4])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
            loadDroppedURLs(from: providers) { urls in
                model.addDroppedBatchFiles(urls, asSource: asSource)
            }
        }
    }

    private var batchHeaderBar: some View {
        @Bindable var model = model
        return HStack(spacing: Space.sm) {
            Button("Folders…", systemImage: "folder") {
                model.openBatchFoldersWorkflow()
            }
            .controlSize(.small)
            .help("Select Source and Target folders to auto-pair episodes (Option-Command-O)")

            Button("Rules…", systemImage: "slider.horizontal.3") {
                showTrackRulesPopover.toggle()
            }
            .controlSize(.small)
            .popover(isPresented: $showTrackRulesPopover, arrowEdge: .bottom) {
                BatchTrackRulesPopover()
                    .environment(model)
            }
            .help("Configure batch-wide audio and subtitle track selection rules")

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
            .help("Presets, add row, retry flagged, and manual merge actions")

            Spacer(minLength: Space.sm)

            if model.isRunning {
                Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                    model.togglePauseQueue()
                }
                .controlSize(.small)
                .help("Pause or resume after the current episode (Option-Command-P)")

                Button("Cancel", role: .destructive) {
                    model.cancelActiveJob()
                }
                .controlSize(.small)
                .help("Cancel the active episode (Command-Period)")
            } else {
                Button {
                    model.startBatchQueue()
                } label: {
                    Label("Start Batch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.dependencies.allRequiredReady || !model.batchJobs.contains(where: \.hasRequiredInputs))
                .help("Start processing queued episodes (Command-R)")
            }
        }
    }

    private var queueListSection: some View {
        @Bindable var model = model
        return List(selection: $model.selectedBatchJobIDs) {
            ForEach(model.batchJobs) { job in
                BatchJobRow(job: job)
                    .tag(job.id)
                    .contextMenu {
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
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(job.episodeBadge) · Pairing & Track Overrides")
                            .font(.headline)
                        if !job.isExactMatch {
                            Label("Review Pairing", systemImage: "exclamationmark.circle")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Surfaces.statusWarning)
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
                                        job.isExactMatch = true
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
                                        job.isExactMatch = true
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

private struct BatchJobRow: View {
    let job: EpisodeJob

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
                    if !job.isExactMatch {
                        Text("Unverified Pair")
                            .foregroundStyle(Surfaces.statusWarning)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: Space.sm)

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
