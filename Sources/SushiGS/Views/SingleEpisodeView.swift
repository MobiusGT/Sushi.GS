import SwiftUI
import SushiGSKit

struct SingleEpisodeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let job = model.singleJob

        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if !model.dependencies.allRequiredReady {
                    MissingDependenciesBanner(
                        missingCount: model.dependencies.missingRequiredDependencies.count,
                        isInstalling: model.dependencies.isBusy,
                        onInstall: { Task { await model.dependencies.installAllRequired(config: model.config) } },
                        onOpenDependencies: { model.sidebar = .dependencies }
                    )
                    .gridProbe("depBanner", area: "single")
                }

                WarningBannerView(job: job) { warning in
                    model.jumpToWarning(warning, in: job)
                }

                if let error = job.errorMessage ?? job.probeError {
                    ErrorBannerView(message: error) {
                        model.showInspector = true
                        model.logScope = .selectedJob
                    }
                }

                // Side-by-side Source and Target drop zones
                HStack(alignment: .top, spacing: Space.lg) {
                    FileDropZoneCard(
                        title: "Source Media",
                        subtitle: "Drop the video or audio that matches your subtitles",
                        symbol: "film",
                        fileURL: job.sourceURL,
                        probe: job.sourceProbe,
                        isProbing: job.isProbingSource,
                        acceptedExtensions: EpisodePairing.mediaExtensions,
                        onChoose: { model.openSingleSourcePanel() },
                        onDropFile: { model.setSingleSource($0) },
                        onClear: {
                            job.sourceURL = nil
                            job.sourceProbe = nil
                            job.selectedSourceAudioID = nil
                            job.selectedSubtitleIDs = []
                            model.syncMenuState()
                        }
                    )

                    FileDropZoneCard(
                        title: "Target Media",
                        subtitle: "Drop the target video to sync to",
                        symbol: "sparkles.tv",
                        fileURL: job.targetURL,
                        probe: job.targetProbe,
                        isProbing: job.isProbingTarget,
                        acceptedExtensions: EpisodePairing.mediaExtensions,
                        onChoose: { model.openSingleTargetPanel() },
                        onDropFile: { model.setSingleTarget($0) },
                        onClear: {
                            job.targetURL = nil
                            job.targetProbe = nil
                            job.selectedTargetAudioID = nil
                            model.syncMenuState()
                        }
                    )
                }
                .gridProbe("dropZones", area: "single")

                // Explicit Audio & Subtitle Track Selection
                TrackSelectionCard(
                    job: job,
                    onChooseExternalSub: { model.openSingleSubtitlePanel() },
                    onClearExternalSub: { model.setSingleExternalSubtitle(nil) }
                )
                .gridProbe("trackCard", area: "single")

                // Workflow Options & Action Strip
                workflowActionCard(job: job)
                    .gridProbe("actionCard", area: "single")

                // Output & Telemetry Summary (shown when running or finished)
                if job.status != .pending || !job.syncedFiles.isEmpty || job.mergedFilepath != nil {
                    resultCard(job: job)
                        .gridProbe("resultCard", area: "single")
                }
            }
            .padding(Space.margin)
            .gridArea("single", inset: Space.margin)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func workflowActionCard(job: EpisodeJob) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Menu {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.applyPreset(preset) }
                    }
                } label: {
                    Label(activePresetName, systemImage: "slider.horizontal.below.rectangle")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .hoverDescription("Apply a saved sync and merge preset")

                Toggle("24 kHz HQ", isOn: $model.config.sync.useHighQualityResample)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .hoverDescription(SushiHelpText.hq24kHz)

                Toggle("Auto-Merge", isOn: $model.config.merge.autoMergeOnSync)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .disabled(!model.dependencies.isInstalled(.mkvmerge))
                    .hoverDescription(model.dependencies.isInstalled(.mkvmerge)
                                      ? SushiHelpText.autoMerge
                                      : SushiHelpText.autoMergeMissing)

                Spacer(minLength: Space.sm)

                if model.isRunning {
                    Button(model.isCancelling ? "Cancelling…" : "Cancel", role: .destructive) {
                        model.cancelActiveJob()
                    }
                    .disabled(model.isCancelling)
                    .keyboardShortcut(.cancelAction)
                    .hoverDescription("Stop the running sync and remove temporary and partial output files (Command-Period)")
                } else {
                    Button("Clear") {
                        model.clearSingleEpisode()
                    }
                    .controlSize(.small)
                    .disabled(!job.hasAnyStateToClear)
                    .fixedSize()
                    .hoverDescription("Clear files, status, metrics, warnings, and logs to start fresh (Shift-Command-K)")

                    if job.canMergeManually && model.dependencies.isInstalled(.mkvmerge) {
                        Button("Merge MKV") {
                            model.mergeCompletedJobs()
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .hoverDescription("Merge the synced subtitle into a new MKV (Shift-Command-M)")
                    }
                    Button {
                        model.runSingleEpisode(mode: "sync")
                    } label: {
                        Label("Sync", systemImage: "waveform")
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(!job.hasRequiredInputs || !model.dependencies.allRequiredReady)
                    .hoverDescription("Run Sushi subtitle synchronization (Command-R)")
                }
            }

            Divider()

            InlineSyncOptionsStrip(includeHQToggle: false, framedAsCard: false)

            if job.status == .running {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text(job.stageDetail.isEmpty ? "Processing…" : job.stageDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((job.progress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surfaces.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Surfaces.hairline, lineWidth: 1)
        )
    }

    private func resultCard(job: EpisodeJob) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Label("Sync Results", systemImage: "checkmark.seal")
                    .font(.headline)
                Spacer()
                JobStatusBadge(status: job.status)
            }

            if let metrics = job.metrics {
                HStack(spacing: Space.xl) {
                    metricItem("Average Shift", value: metrics.formattedAverageShift ?? "—")
                    metricItem("Median Diff", value: metrics.medianDiff.map { String(format: "%.3f", $0) } ?? "—")
                    metricItem("Peak Diff", value: metrics.maxDiff.map { String(format: "%.3f", $0) } ?? "—")
                    metricItem("Events", value: "\(metrics.eventCount)")
                    metricItem("Warnings", value: "\(job.warnings.count)")
                }
            }

            if !job.syncedFiles.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Synced Subtitles")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(job.syncedFiles, id: \.self) { path in
                        outputFileRow(path: path, symbol: "captions.bubble")
                    }
                }
            }

            if let merged = job.mergedFilepath {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Merged MKV")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    outputFileRow(path: merged, symbol: "film.stack")
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surfaces.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Surfaces.hairline, lineWidth: 1)
        )
    }

    private func metricItem(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit().weight(.medium))
        }
    }

    private func outputFileRow(path: String, symbol: String) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer()
            Button("Reveal in Finder") {
                model.revealInFinder(path)
            }
            .controlSize(.small)
        }
        .padding(.vertical, Space.xs)
        .contextMenu {
            Button("Reveal in Finder") { model.revealInFinder(path) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }

    private var activePresetName: String {
        model.presets.first(where: { $0.id == model.selectedPresetID })?.name ?? "Preset"
    }
}
