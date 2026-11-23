import AppKit
import SwiftUI
import SushiGSKit
import UniformTypeIdentifiers

struct JobStatusBadge: View {
    let status: JobStatus

    var body: some View {
        Label(status.displayName, systemImage: status.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(foregroundColor.opacity(0.14), in: Capsule())
    }

    private var foregroundColor: Color {
        switch status {
        case .pending, .cancelled: .secondary
        case .running: Surfaces.statusRunning
        case .succeeded: Surfaces.statusSuccess
        case .warned: Surfaces.statusWarning
        case .failed: Surfaces.statusError
        }
    }
}

struct WarningBannerView: View {
    let job: EpisodeJob
    let onJumpToWarning: (SyncWarning) -> Void

    var body: some View {
        if let summary = job.warningBannerSummary {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Surfaces.statusWarning)
                    Text("Audio-Matching Warning")
                        .font(.headline)
                    Spacer()
                    if let first = job.warnings.first {
                        Button("Jump to Warning") {
                            onJumpToWarning(first)
                        }
                        .controlSize(.small)
                        .help("Scroll the Log Inspector to the first flagged line")
                    }
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if job.warnings.count > 1 {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(job.warnings.prefix(4)) { warning in
                            Button {
                                onJumpToWarning(warning)
                            } label: {
                                HStack(spacing: Space.xs) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.caption)
                                    Text(warning.summary)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("Line \(warning.lineIndex + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Surfaces.statusWarning)
                        }
                    }
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surfaces.warningBannerFill, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Surfaces.warningBannerBorder.opacity(0.45), lineWidth: 1)
            )
        }
    }
}

struct ErrorBannerView: View {
    let message: String
    var onOpenLogs: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Surfaces.statusError)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let onOpenLogs {
                Button("View Log", action: onOpenLogs)
                    .controlSize(.small)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surfaces.errorBannerFill, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Surfaces.errorBannerBorder.opacity(0.45), lineWidth: 1)
        )
    }
}

struct MissingDependenciesBanner: View {
    let missingCount: Int
    let isInstalling: Bool
    let onInstall: () -> Void
    let onOpenDependencies: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(Surfaces.statusWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(missingCount) required \(missingCount == 1 ? "dependency is" : "dependencies are") missing")
                    .font(.headline)
                Text("Install uv, Python 3.13, sushi-batch, and FFmpeg directly in Gas Station Sushi.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Manage…", action: onOpenDependencies)
                .controlSize(.small)
            Button("Install Required Dependencies", action: onInstall)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isInstalling)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surfaces.warningBannerFill, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Surfaces.warningBannerBorder.opacity(0.45), lineWidth: 1)
        )
    }
}

struct FileDropZoneCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let fileURL: URL?
    let probe: MediaProbeResult?
    let isProbing: Bool
    let acceptedExtensions: Set<String>
    let onChoose: () -> Void
    let onDropFile: (URL) -> Void
    let onClear: () -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                if fileURL != nil {
                    Button("Change…", action: onChoose)
                        .controlSize(.small)
                    Button("Clear", systemImage: "xmark.circle.fill", action: onClear)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove selected file")
                }
            }

            if let fileURL {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(fileURL.lastPathComponent)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(fileURL.path)
                    if isProbing {
                        HStack(spacing: Space.xs) {
                            ProgressView().controlSize(.small)
                            Text("Inspecting tracks…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let probe {
                        HStack(spacing: Space.sm) {
                            if let dur = probe.formattedDuration {
                                Label(dur, systemImage: "clock")
                            }
                            if let vid = probe.videoTracks.first {
                                Label(vid.resolutionLabel, systemImage: "rectangle.on.rectangle")
                            }
                            Label("\(probe.audioTracks.count) audio", systemImage: "waveform")
                            if !probe.supportedSubtitleTracks.isEmpty {
                                Label("\(probe.supportedSubtitleTracks.count) sub", systemImage: "captions.bubble")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(fileURL.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, Space.xs)
            } else {
                VStack(spacing: Space.sm) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Choose File…", action: onChoose)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, minHeight: 88)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isTargeted ? Palette.accent.opacity(0.10) : Surfaces.card,
            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(
                    isTargeted ? Palette.accent : Surfaces.hairline,
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: fileURL == nil ? [6, 4] : [])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleFileDrop(providers: providers)
        }
        .contextMenu {
            Button("Choose File…", action: onChoose)
            if let fileURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fileURL.path, forType: .string)
                }
                Divider()
                Button("Clear", role: .destructive, action: onClear)
            }
        }
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let ext = url.pathExtension.lowercased()
            guard acceptedExtensions.isEmpty || acceptedExtensions.contains(ext) else { return }
            Task { @MainActor in onDropFile(url) }
        }
        return true
    }
}

/// Explicit Source Audio ↔ Target Audio track pickers + Embedded / External subtitle controls.
struct TrackSelectionCard: View {
    @Bindable var job: EpisodeJob
    var markAsCustomOverride: Bool = false
    let onChooseExternalSub: () -> Void
    let onClearExternalSub: () -> Void
    var onResetToBatchRule: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Label("Tracks & Subtitles", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                if markAsCustomOverride, job.hasCustomTrackOverrides, let onResetToBatchRule {
                    Button("Reset to Batch Rule", action: onResetToBatchRule)
                        .controlSize(.small)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
                GridRow {
                    Text("Source Audio")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    sourceAudioPicker
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GridRow {
                    Text("Target Audio")
                        .foregroundStyle(.secondary)
                    targetAudioPicker
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GridRow {
                    Text("Subtitle Source")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Picker("Subtitle Source", selection: Binding(
                            get: { job.useExternalSubtitle },
                            set: { newVal in
                                job.useExternalSubtitle = newVal
                                if markAsCustomOverride { job.hasCustomTrackOverrides = true }
                            }
                        )) {
                            Text("Embedded in Source").tag(false)
                            Text("External Subtitle File").tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)

                        if job.useExternalSubtitle {
                            externalSubtitleControls
                        } else {
                            embeddedSubtitleSelector
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private var sourceAudioPicker: some View {
        let tracks = job.sourceProbe?.audioTracks ?? []
        if tracks.isEmpty {
            Text(job.sourceURL == nil ? "Drop a Source file to inspect audio tracks" : "No audio tracks detected")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let current = tracks.first(where: { $0.id == job.selectedSourceAudioID }) ?? tracks[0]
            Menu {
                ForEach(tracks) { track in
                    Button {
                        job.selectedSourceAudioID = track.id
                        if markAsCustomOverride { job.hasCustomTrackOverrides = true }
                    } label: {
                        if track.id == current.id {
                            Label(track.displayLabel, systemImage: "checkmark")
                        } else {
                            Text(track.displayLabel)
                        }
                    }
                }
            } label: {
                trackMenuLabel(current.displayLabel)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    @ViewBuilder
    private var targetAudioPicker: some View {
        let tracks = job.targetProbe?.audioTracks ?? []
        if tracks.isEmpty {
            Text(job.targetURL == nil ? "Drop a Target file to inspect audio tracks" : "No audio tracks detected")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let current = tracks.first(where: { $0.id == job.selectedTargetAudioID }) ?? tracks[0]
            Menu {
                ForEach(tracks) { track in
                    Button {
                        job.selectedTargetAudioID = track.id
                        if markAsCustomOverride { job.hasCustomTrackOverrides = true }
                    } label: {
                        if track.id == current.id {
                            Label(track.displayLabel, systemImage: "checkmark")
                        } else {
                            Text(track.displayLabel)
                        }
                    }
                }
            } label: {
                trackMenuLabel(current.displayLabel)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private func trackMenuLabel(_ text: String) -> some View {
        HStack(spacing: Space.sm) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Space.sm)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .strokeBorder(Surfaces.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var embeddedSubtitleSelector: some View {
        let tracks = job.sourceProbe?.subtitleTracks ?? []
        if tracks.isEmpty {
            HStack(spacing: Space.sm) {
                Text(job.sourceURL == nil ? "Drop a Source video to inspect embedded subtitles." : "No embedded text subtitles found in Source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if job.sourceURL != nil {
                    Button("Choose External Subtitle…", action: onChooseExternalSub)
                        .controlSize(.small)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(tracks) { track in
                    Toggle(isOn: Binding(
                        get: { job.selectedSubtitleIDs.contains(track.id) },
                        set: { checked in
                            if checked {
                                job.selectedSubtitleIDs.insert(track.id)
                            } else {
                                job.selectedSubtitleIDs.remove(track.id)
                            }
                            if markAsCustomOverride { job.hasCustomTrackOverrides = true }
                        }
                    )) {
                        Text(track.displayLabel)
                            .font(.callout)
                            .foregroundStyle(track.supported ? .primary : .tertiary)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!track.supported)
                }
                if job.selectedSubtitleIDs.count > 1 {
                    Text("Multiple tracks selected: each track will be retimed to its own `.sushi` output file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var externalSubtitleControls: some View {
        HStack(spacing: Space.sm) {
            if let ext = job.externalSubtitleURL {
                Label(ext.lastPathComponent, systemImage: "captions.bubble")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ext.path)
                Button("Change…", action: onChooseExternalSub)
                    .controlSize(.small)
                Button("Clear", action: onClearExternalSub)
                    .controlSize(.small)
            } else {
                Text("Select an `.ass`, `.srt`, or `.ssa` file to retime.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Choose Subtitle…", action: onChooseExternalSub)
                    .controlSize(.small)
            }
        }
    }
}
