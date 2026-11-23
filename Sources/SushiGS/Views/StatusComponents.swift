import AppKit
import SwiftUI
import SushiGSKit
import UniformTypeIdentifiers

/// Concise plain-English hover descriptions for non-obvious sync, merge, and audio settings.
/// Shown exclusively on hover via `.hoverDescription(...)` so the UI stays clutter-free at rest.
enum SushiHelpText {
    static let hq24kHz = "Resample audio to 24 kHz instead of 12 kHz for sharper subtitle timing accuracy on subtle cuts, at a modest speed cost (--sample-rate 24000)."
    static let window = "Seconds of audio searched forward and backward around each line to find its shift (default 10s, --window)."
    static let maxWindow = "Expanded search window in seconds used automatically when a cut or break exceeds the normal window (default 30s, --max-window)."
    static let keyframeSnapping = "Align shifted subtitle boundaries to video scene-change keyframes for crisp transitions (--src-keyframes / --dst-keyframes)."
    static let keyframeMode = "Choose whether keyframes guide overall segment shifts, snap line edges to scene cuts, or both (--kf-mode)."
    static let maxKfDistance = "Maximum distance in frames a subtitle edge can move when snapping to a nearby video keyframe (default 2.0, --max-kf-distance)."
    static let fpsOverride = "Optional frame-rate override (e.g. 23.976) used when aligning external keyframe files (--src-fps / --dst-fps)."
    static let chapters = "Use MKV chapter markers to split shift groups cleanly at openings, endings, and commercial breaks (--chapters)."
    static let grouping = "Cluster consecutive lines into shift groups and smooth outliers; disable only for erratic, non-linear cuts (--no-grouping)."
    static let rewindThresh = "Consecutive matching lines needed before Sushi starts a new shift group after a scene jump (default 5, --rewind-thresh)."
    static let smoothRadius = "Neighboring lines used for median smoothing inside each group to filter out noisy matches (default 3, --smooth-radius)."
    static let maxTsDuration = "Lines shorter than this duration in seconds are treated as signs/typesetting and inherit neighboring shifts (default 0.417s, --max-ts-duration)."
    static let maxTsDistance = "Maximum gap in seconds between adjacent typesetting lines to group them together (default 0.417s, --max-ts-distance)."
    static let verboseLogging = "Emit detailed per-segment Sushi diagnostics into the Log Inspector (-v)."
    static let autoMerge = "Automatically mux synced subtitles into a new MKV alongside the Target video after syncing finishes."
    static let autoMergeMissing = "Install MKVMerge in Dependencies to enable automatic MKV merging."
    static let resampleSubs = "Scale ASS subtitle coordinates and fonts via aegisub-cli to match Target video resolution before merging."
    static let resampleSubsMissing = "Install aegisub-cli in Dependencies to enable subtitle resolution resampling."
    static let deleteGenerated = "Remove standalone .sushi subtitle and temporary encoded audio files after MKV merging succeeds."
    static let audioEncode = "Transcode lossless Target audio (FLAC or WAV) to Opus, AAC, or EAC-3 before merging; lossy tracks are copied untouched."
    static let audioTracksScope = "Encode only the Target audio track used for syncing, or every lossless audio track in the Target file."
    static let opusEncoder = "Choose between FFmpeg's built-in libopus encoder or the external opusenc binary from opus-tools."
    static let onlyKeepSyncAudio = "Keep only the Target audio track used for syncing in the merged MKV and drop other Target audio tracks."
    static let copySourceAttachments = "Include embedded fonts and cover art from the Source MKV so styled ASS subtitles render properly."
    static let copySourceChapters = "Use chapter markers from the Source file instead of keeping only Target chapters."
    static let copyTargetAttachmentsChapters = "Preserve fonts, cover art, and chapter markers already present in the Target file."
    static let copyTargetSubtitles = "Keep original subtitle tracks from the Target MKV alongside the newly synced subtitle."
    static let copyTargetTags = "Preserve global and per-track metadata tags from the Target MKV."
    static let customOutputDir = "Write synced subtitles and Merged Files to a chosen folder instead of beside each Target file."
}

extension View {
    /// Applies a native macOS hover tooltip across the full control/label hit area without adding visible prose at rest.
    func hoverDescription(_ text: String) -> some View {
        self
            .contentShape(Rectangle())
            .help(text)
    }
}

/// Compact collapsible quick-overrides strip for high-value Sushi flags, shared by Single Episode and Batch Queue.
struct InlineSyncOptionsStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var includeHQToggle: Bool = true
    var framedAsCard: Bool = true
    @State private var isExpanded = false

    var body: some View {
        @Bindable var model = model

        let content = DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Divider()
                    .padding(.top, Space.xs)

                // Row 1: Quick toggles & search windows
                HStack(spacing: Space.lg) {
                    if includeHQToggle {
                        Toggle("24 kHz HQ", isOn: $model.config.sync.useHighQualityResample)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .hoverDescription(SushiHelpText.hq24kHz)
                    }

                    HStack(spacing: Space.xs) {
                        Text("Window")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("\(model.config.sync.advancedArgs.window)s")
                            .font(.callout.monospacedDigit())
                            .frame(minWidth: 32, alignment: .trailing)
                        Stepper("", value: $model.config.sync.advancedArgs.window, in: 2...120)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                    .hoverDescription(SushiHelpText.window)

                    HStack(spacing: Space.xs) {
                        Text("Max Window")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("\(model.config.sync.advancedArgs.maxWindow)s")
                            .font(.callout.monospacedDigit())
                            .frame(minWidth: 36, alignment: .trailing)
                        Stepper("", value: $model.config.sync.advancedArgs.maxWindow, in: 5...300)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                    .hoverDescription(SushiHelpText.maxWindow)

                    Spacer(minLength: Space.xs)
                }

                // Row 2: Keyframe snapping & chapters
                HStack(spacing: Space.lg) {
                    HStack(spacing: Space.xs) {
                        Text("Keyframes")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Picker("Keyframes", selection: $model.config.sync.keyframesSource) {
                            Text("Off").tag(KeyframesSourceOption.none)
                            Text("Auto").tag(KeyframesSourceOption.auto)
                            Text("Generate").tag(KeyframesSourceOption.make)
                            Text("Files").tag(KeyframesSourceOption.files)
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 96)
                    }
                    .hoverDescription(SushiHelpText.keyframeSnapping)

                    if model.config.sync.keyframesSource == .files {
                        HStack(spacing: Space.xs) {
                            Button(model.config.sync.srcKeyframesFile.isEmpty ? "Src…" : "Src ✓") {
                                if let url = model.pickSingleFile(title: "Choose Source Keyframes File", allowedExtensions: ["txt", "log", "keyframes"]) {
                                    model.config.sync.srcKeyframesFile = url.path
                                }
                            }
                            .controlSize(.small)
                            .hoverDescription("Choose external Source keyframes file (--src-keyframes).")

                            Button(model.config.sync.dstKeyframesFile.isEmpty ? "Dst…" : "Dst ✓") {
                                if let url = model.pickSingleFile(title: "Choose Target Keyframes File", allowedExtensions: ["txt", "log", "keyframes"]) {
                                    model.config.sync.dstKeyframesFile = url.path
                                }
                            }
                            .controlSize(.small)
                            .hoverDescription("Choose external Target keyframes file (--dst-keyframes).")
                        }
                    }

                    if model.config.sync.keyframesSource != .none {
                        HStack(spacing: Space.xs) {
                            Text("Mode")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Picker("Mode", selection: $model.config.sync.kfMode) {
                                Text("All").tag(KeyframeSnapModeOption.all)
                                Text("Shift").tag(KeyframeSnapModeOption.shift)
                                Text("Snap").tag(KeyframeSnapModeOption.snap)
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 80)
                        }
                        .hoverDescription(SushiHelpText.keyframeMode)
                    }

                    HStack(spacing: Space.xs) {
                        Text("Chapters")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Picker("Chapters", selection: $model.config.sync.chaptersMode) {
                            Text("Auto").tag(ChaptersModeOption.auto)
                            Text("Ignore").tag(ChaptersModeOption.none)
                            Text("File…").tag(ChaptersModeOption.file)
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 88)

                        if model.config.sync.chaptersMode == .file {
                            Button(chaptersButtonTitle) {
                                if let url = model.pickSingleFile(title: "Choose Chapters File", allowedExtensions: ["xml", "txt"]) {
                                    model.config.sync.chaptersFile = url.path
                                }
                            }
                            .controlSize(.small)
                            .lineLimit(1)
                        }
                    }
                    .hoverDescription(SushiHelpText.chapters)

                    Spacer(minLength: Space.xs)

                    if hasNonDefaultQuickSettings {
                        Button("Reset") {
                            resetQuickSettings()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                        .hoverDescription("Restore Window, Max Window, Keyframes, and Chapters to defaults.")
                    }

                    Button("All Sync Settings…") {
                        model.settingsTab = .sync
                        openSettings()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Palette.accentText)
                    .hoverDescription("Open Settings → Sync for Rewind Threshold, Smoothing Radius, Grouping, and Typesetting limits.")
                }
            }
            .padding(.top, Space.xs)
        } label: {
            HStack(spacing: Space.sm) {
                Label("Sync Options", systemImage: "waveform.path")
                    .font(.callout.weight(.medium))
                Text(compactSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Space.sm)
            }
            .contentShape(Rectangle())
        }

        if framedAsCard {
            content
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Surfaces.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(Surfaces.hairline, lineWidth: 1)
                )
        } else {
            content
        }
    }

    private var compactSummary: String {
        let s = model.config.sync
        var parts: [String] = []
        if includeHQToggle {
            parts.append(s.useHighQualityResample ? "24 kHz HQ" : "12 kHz")
        }
        parts.append("Window \(s.advancedArgs.window)s / \(s.advancedArgs.maxWindow)s")
        if s.keyframesSource != .none {
            parts.append("Keyframes: \(s.keyframesSource.rawValue.capitalized) (\(s.kfMode.rawValue))")
        } else {
            parts.append("Keyframes: Off")
        }
        switch s.chaptersMode {
        case .auto: parts.append("Chapters: Auto")
        case .none: parts.append("Chapters: Off")
        case .file:
            let name = s.chaptersFile.isEmpty ? "File" : URL(fileURLWithPath: s.chaptersFile).lastPathComponent
            parts.append("Chapters: \(name)")
        }
        return parts.joined(separator: " · ")
    }

    private var chaptersButtonTitle: String {
        let path = model.config.sync.chaptersFile
        return path.isEmpty ? "Choose…" : URL(fileURLWithPath: path).lastPathComponent
    }

    private var hasNonDefaultQuickSettings: Bool {
        let s = model.config.sync
        return s.advancedArgs.window != SushiAdvancedArgs.defaultWindow
            || s.advancedArgs.maxWindow != SushiAdvancedArgs.defaultMaxWindow
            || s.keyframesSource != .none
            || s.chaptersMode != .auto
    }

    private func resetQuickSettings() {
        model.config.sync.advancedArgs.window = SushiAdvancedArgs.defaultWindow
        model.config.sync.advancedArgs.maxWindow = SushiAdvancedArgs.defaultMaxWindow
        model.config.sync.keyframesSource = .none
        model.config.sync.kfMode = .all
        model.config.sync.chaptersMode = .auto
        model.config.sync.chaptersFile = ""
    }
}

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
