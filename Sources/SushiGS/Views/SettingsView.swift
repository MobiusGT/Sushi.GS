import AppKit
import SwiftUI
import SushiGSKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general: GeneralSettingsTab()
            case .sync: SyncSettingsTab()
            case .merge: MergeSettingsTab()
            case .audio: AudioEncodeSettingsTab()
            case .dependencies: DependenciesSettingsTab()
            case .appearance: AppearanceSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent(max: 760)
        .frame(width: 540)
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var newPresetName = ""

    var body: some View {
        @Bindable var model = model

        Section("Output Placement") {
            Toggle("Save outputs to a custom folder", isOn: $model.config.general.useCustomOutputDirectory)
                .controlSize(.mini)
                .hoverDescription(SushiHelpText.customOutputDir)

            if model.config.general.useCustomOutputDirectory {
                LabeledContent("Output folder") {
                    HStack(spacing: Space.sm) {
                        Text(model.config.general.customOutputDirectory.isEmpty ? "Not set" : model.config.general.customOutputDirectory)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            if let folder = model.pickFolder(title: "Choose Output Directory") {
                                model.config.general.customOutputDirectory = folder.path
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .hoverDescription(SushiHelpText.customOutputDir)
            }
        }

        Section("Log Files") {
            Toggle("Save Sushi sync logs to Application Support", isOn: $model.config.general.saveSushiLogs)
                .controlSize(.mini)
                .hoverDescription("Write a timestamped Sushi log file for every sync run inside Application Support/Sushi.GS/logs.")
            Toggle("Save MKVMerge and audio-encode logs", isOn: $model.config.general.saveMergeLogs)
                .controlSize(.mini)
                .hoverDescription("Write MKVMerge and audio re-encoding logs inside Application Support/Sushi.GS/logs.")
            LabeledContent("Runtime & logs folder") {
                Button("Open in Finder") {
                    NSWorkspace.shared.open(model.paths.rootDir)
                }
                .controlSize(.small)
            }
            .hoverDescription("Reveal ~/Library/Application Support/Sushi.GS in Finder.")
        }

        Section("Reusable Presets") {
            HStack(spacing: Space.sm) {
                TextField("New preset name…", text: $newPresetName)
                Button("Save Current") {
                    model.saveCurrentAsPreset(named: newPresetName)
                    newPresetName = ""
                }
                .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ForEach(model.presets) { preset in
                HStack {
                    Text(preset.name)
                    if preset.isBuiltIn {
                        Text("Built-in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply") { model.applyPreset(preset) }
                        .controlSize(.small)
                    if !preset.isBuiltIn {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.deletePreset(preset)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Delete preset")
                    }
                }
            }
        }
    }
}

private struct SyncSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Section("Audio Matching & Search Window") {
            Toggle("24 kHz HQ audio resampling", isOn: $model.config.sync.useHighQualityResample)
                .controlSize(.mini)
                .hoverDescription(SushiHelpText.hq24kHz)

            Stepper(
                "Window: \(model.config.sync.advancedArgs.window) s",
                value: $model.config.sync.advancedArgs.window,
                in: 2...120
            )
            .hoverDescription(SushiHelpText.window)

            Stepper(
                "Max Window: \(model.config.sync.advancedArgs.maxWindow) s",
                value: $model.config.sync.advancedArgs.maxWindow,
                in: 5...300
            )
            .hoverDescription(SushiHelpText.maxWindow)

            Toggle("Group and smooth shifts across segments", isOn: $model.config.sync.grouping)
                .controlSize(.mini)
                .hoverDescription(SushiHelpText.grouping)
        }

        Section("Grouping, Smoothing & Typesetting") {
            Stepper(
                "Rewind threshold: \(model.config.sync.advancedArgs.rewindThresh) events",
                value: $model.config.sync.advancedArgs.rewindThresh,
                in: 0...50
            )
            .hoverDescription(SushiHelpText.rewindThresh)

            Stepper(
                "Smoothing radius: \(model.config.sync.advancedArgs.smoothRadius) events",
                value: $model.config.sync.advancedArgs.smoothRadius,
                in: 0...25
            )
            .hoverDescription(SushiHelpText.smoothRadius)

            LabeledContent("Max typesetting duration (s)") {
                TextField("", value: $model.config.sync.advancedArgs.maxTsDuration, format: .number, prompt: Text("0.417"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            .hoverDescription(SushiHelpText.maxTsDuration)

            LabeledContent("Max typesetting distance (s)") {
                TextField("", value: $model.config.sync.advancedArgs.maxTsDistance, format: .number, prompt: Text("0.417"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            .hoverDescription(SushiHelpText.maxTsDistance)
        }

        Section("Chapters & Keyframe Snapping") {
            Picker("Chapters", selection: $model.config.sync.chaptersMode) {
                ForEach(ChaptersModeOption.allCases) { opt in
                    Text(opt.displayName).tag(opt)
                }
            }
            .hoverDescription(SushiHelpText.chapters)

            if model.config.sync.chaptersMode == .file {
                LabeledContent("Chapters file") {
                    HStack(spacing: Space.sm) {
                        Text(model.config.sync.chaptersFile.isEmpty ? "None" : URL(fileURLWithPath: model.config.sync.chaptersFile).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            if let url = model.pickSingleFile(title: "Choose Chapters File", allowedExtensions: ["xml", "txt"]) {
                                model.config.sync.chaptersFile = url.path
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .hoverDescription(SushiHelpText.chapters)
            }

            Picker("Keyframe snapping", selection: $model.config.sync.keyframesSource) {
                ForEach(KeyframesSourceOption.allCases) { opt in
                    Text(opt.displayName).tag(opt)
                }
            }
            .hoverDescription(SushiHelpText.keyframeSnapping)

            if model.config.sync.keyframesSource == .files {
                LabeledContent("Source keyframes file") {
                    HStack(spacing: Space.sm) {
                        Text(model.config.sync.srcKeyframesFile.isEmpty ? "None" : URL(fileURLWithPath: model.config.sync.srcKeyframesFile).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            if let url = model.pickSingleFile(title: "Choose Source Keyframes File", allowedExtensions: ["txt", "log", "keyframes"]) {
                                model.config.sync.srcKeyframesFile = url.path
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .hoverDescription(SushiHelpText.keyframeSnapping)

                LabeledContent("Target keyframes file") {
                    HStack(spacing: Space.sm) {
                        Text(model.config.sync.dstKeyframesFile.isEmpty ? "None" : URL(fileURLWithPath: model.config.sync.dstKeyframesFile).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            if let url = model.pickSingleFile(title: "Choose Target Keyframes File", allowedExtensions: ["txt", "log", "keyframes"]) {
                                model.config.sync.dstKeyframesFile = url.path
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .hoverDescription(SushiHelpText.keyframeSnapping)
            }

            if model.config.sync.keyframesSource != .none {
                Picker("Keyframe mode", selection: $model.config.sync.kfMode) {
                    ForEach(KeyframeSnapModeOption.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .hoverDescription(SushiHelpText.keyframeMode)

                LabeledContent("Max keyframe distance (frames)") {
                    TextField("", value: $model.config.sync.maxKfDistance, format: .number, prompt: Text("2.0"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                .hoverDescription(SushiHelpText.maxKfDistance)

                LabeledContent("FPS override (Source / Target)") {
                    HStack(spacing: Space.sm) {
                        TextField("", text: $model.config.sync.srcFps, prompt: Text("Auto"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                        Text("/")
                            .foregroundStyle(.secondary)
                        TextField("", text: $model.config.sync.dstFps, prompt: Text("Auto"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                    }
                }
                .hoverDescription(SushiHelpText.fpsOverride)
            }
        }

        Section("Diagnostics") {
            Toggle("Verbose Sushi diagnostic logging", isOn: $model.config.sync.verboseLogging)
                .controlSize(.mini)
                .hoverDescription(SushiHelpText.verboseLogging)

            LabeledContent("Sync defaults") {
                Button("Reset Sync Defaults") {
                    model.config.sync = SyncSettings()
                }
                .controlSize(.small)
                .disabled(model.config.sync == SyncSettings())
            }
            .hoverDescription("Restore all Sync parameters to their default values.")
        }
    }
}

private struct MergeSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let hasMKVMerge = model.dependencies.isInstalled(.mkvmerge)
        let hasAegisub = model.dependencies.isInstalled(.aegisubCLI)

        Section {
            Toggle("Merge automatically after sync completes", isOn: $model.config.merge.autoMergeOnSync)
                .controlSize(.mini)
                .disabled(!hasMKVMerge)
                .hoverDescription(hasMKVMerge ? SushiHelpText.autoMerge : SushiHelpText.autoMergeMissing)

            Toggle("Resample synced subtitle resolution before merge", isOn: $model.config.merge.resampleSubsBeforeMerge)
                .controlSize(.mini)
                .disabled(!hasAegisub)
                .hoverDescription(hasAegisub ? SushiHelpText.resampleSubs : SushiHelpText.resampleSubsMissing)

            Toggle("Delete generated subtitle and audio files after merge", isOn: $model.config.merge.deleteGeneratedFilesAfterMerge)
                .controlSize(.mini)
                .hoverDescription(SushiHelpText.deleteGenerated)
        } header: {
            Text("Merge Workflow")
        } footer: {
            if !hasAegisub {
                Text("Subtitle resampling requires aegisub-cli in Dependencies.")
            } else if !hasMKVMerge {
                Text("Automatic MKV merging requires MKVMerge in Dependencies.")
            }
        }

        Section("Synced Subtitle Track Flags") {
            Toggle("Set default track flag", isOn: $model.config.merge.syncedSubtitle.setDefaultFlag)
                .controlSize(.mini)
                .hoverDescription("Mark the synced subtitle track as the default subtitle track in the merged MKV.")
            Toggle("Set forced display flag", isOn: $model.config.merge.syncedSubtitle.setForcedFlag)
                .controlSize(.mini)
                .hoverDescription("Mark the synced subtitle track as forced (typically used for signs & songs tracks).")
            Toggle("Override merged subtitle track name", isOn: $model.config.merge.syncedSubtitle.overrideTrackTitle)
                .controlSize(.mini)
                .hoverDescription("Replace the Source subtitle track's original title with a custom label in the merged MKV.")
            if model.config.merge.syncedSubtitle.overrideTrackTitle {
                TextField("Custom track name", text: $model.config.merge.syncedSubtitle.customTrackTitle)
            }
        }

        Section("Tracks & Metadata to Copy") {
            Toggle("Copy Source attachments (fonts & cover art)", isOn: $model.config.merge.source.copyAttachments)
                .controlSize(.mini)
                .hoverDescription(SushiHelpText.copySourceAttachments)
            Toggle("Copy Source chapters", isOn: $model.config.merge.source.copyChapters)
                .controlSize(.mini)
                .hoverDescription(SushiHelpText.copySourceChapters)
            Toggle("Copy Target attachments & chapters", isOn: Binding(
                get: { model.config.merge.target.copyAttachments && model.config.merge.target.copyChapters },
                set: {
                    model.config.merge.target.copyAttachments = $0
                    model.config.merge.target.copyChapters = $0
                }
            ))
            .controlSize(.mini)
            .hoverDescription(SushiHelpText.copyTargetAttachmentsChapters)
            Toggle("Copy Target existing subtitles", isOn: $model.config.merge.target.copySubtitles)
                .controlSize(.mini)
                .hoverDescription(SushiHelpText.copyTargetSubtitles)
            Toggle("Only keep Target audio track used for sync", isOn: $model.config.merge.target.onlyIncludeSyncAudioTrack)
                .controlSize(.mini)
                .hoverDescription(SushiHelpText.onlyKeepSyncAudio)
            Toggle("Copy Target global & track tags", isOn: Binding(
                get: { model.config.merge.target.copyGlobalTags && model.config.merge.target.copyTrackTags },
                set: {
                    model.config.merge.target.copyGlobalTags = $0
                    model.config.merge.target.copyTrackTags = $0
                }
            ))
            .controlSize(.mini)
            .hoverDescription(SushiHelpText.copyTargetTags)
        }
    }
}

private struct AudioEncodeSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Section("Lossless Audio Re-Encoding") {
            Toggle("Re-encode lossless audio (FLAC / WAV) before merging", isOn: $model.config.audioEncode.enabled)
                .controlSize(.mini)
                .hoverDescription(SushiHelpText.audioEncode)

            Picker("Target codec", selection: $model.config.audioEncode.codec) {
                ForEach(AudioEncodeCodecOption.allCases) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
            .disabled(!model.config.audioEncode.enabled)
            .hoverDescription("Lossy codec used when transcoding lossless Target audio tracks.")

            Picker("Tracks to encode", selection: $model.config.audioEncode.tracksScope) {
                ForEach(AudioTracksToEncodeOption.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .disabled(!model.config.audioEncode.enabled)
            .hoverDescription(SushiHelpText.audioTracksScope)

            if model.config.audioEncode.codec == .opus {
                Picker("Opus encoder", selection: $model.config.audioEncode.opusEncoder) {
                    ForEach(OpusEncoderOption.allCases) { enc in
                        Text(enc.displayName).tag(enc)
                    }
                }
                .disabled(!model.config.audioEncode.enabled)
                .hoverDescription(SushiHelpText.opusEncoder)
            }
        }

        Section("Target Bitrates (\(model.config.audioEncode.codec.displayName))") {
            HStack(spacing: Space.sm) {
                bitrateField("Mono", text: $model.config.audioEncode.activeBitrates.mono)
                bitrateField("Stereo", text: $model.config.audioEncode.activeBitrates.stereo)
                bitrateField("5.1", text: $model.config.audioEncode.activeBitrates.surround51)
                bitrateField("7.1", text: $model.config.audioEncode.activeBitrates.surround71)
            }
            .disabled(!model.config.audioEncode.enabled)
            .hoverDescription("Target bitrate per channel layout when re-encoding lossless audio.")
        }
    }

    private func bitrateField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text("128k"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct DependenciesSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let deps = model.dependencies

        Section("Status Summary") {
            LabeledContent("Required runtime") {
                HStack(spacing: Space.sm) {
                    Text(deps.allRequiredReady ? "Ready" : "\(deps.missingRequiredDependencies.count) missing")
                        .foregroundStyle(deps.allRequiredReady ? Surfaces.statusSuccess : Surfaces.statusWarning)
                    Button("Refresh & Verify") {
                        Task { await deps.refreshAll(config: model.config, checkRemoteUpdates: true) }
                    }
                    .controlSize(.small)
                    .disabled(deps.isBusy)
                }
            }
            if !deps.allRequiredReady {
                Button("Install Required Dependencies") {
                    Task { await deps.installAllRequired(config: model.config) }
                }
                .disabled(deps.isBusy)
            }
        }

        Section("Upstream Package Override") {
            TextField("GitHub branch or tag (blank = PyPI)", text: $model.config.general.sushiBatchGitRef)
                .hoverDescription("Leave blank to install the latest sushi-batch release from PyPI, or enter a branch/tag to install from GitHub.")
            HStack {
                Spacer()
                Button("Install / Update sushi-batch") {
                    Task { await deps.installOrUpdate(.sushiBatch, config: model.config) }
                }
                .controlSize(.small)
                .disabled(deps.isBusy)
            }
        }

        Section("Manual Binary Path Overrides") {
            ForEach([DependencyID.uv, .ffmpeg, .ffprobe, .mkvmerge, .opusenc, .aegisubCLI], id: \.self) { depID in
                if let key = depID.executableName {
                    LabeledContent(depID.displayName) {
                        HStack(spacing: Space.xs) {
                            Text(model.config.binaryOverrides[key] ?? deps.records[depID]?.resolvedPath ?? "Auto-detect")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 200, alignment: .trailing)
                            Button("Browse…") {
                                model.pickBinaryOverride(for: depID)
                            }
                            .controlSize(.small)
                            if model.config.binaryOverrides[key] != nil {
                                Button("Reset", systemImage: "xmark.circle.fill") {
                                    model.config.binaryOverrides.removeValue(forKey: key)
                                    Task { await deps.refreshAll(config: model.config, checkRemoteUpdates: false) }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
