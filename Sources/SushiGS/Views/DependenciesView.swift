import AppKit
import SwiftUI
import SushiGSKit

struct DependenciesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var deps = model.dependencies

        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                summaryHeader
                    .gridProbe("depHeader", area: "deps")

                dependencySection(
                    title: "Required Dependencies",
                    subtitle: "Core runtime and media tools needed for subtitle synchronization.",
                    records: deps.orderedRequired
                )
                .gridProbe("reqSection", area: "deps")

                dependencySection(
                    title: "Optional Tools",
                    subtitle: "Install these to unlock MKV merging, Xiph Opus encoding, and subtitle resolution resampling.",
                    records: deps.orderedOptional
                )
                .gridProbe("optSection", area: "deps")

                installLogDisclosure
                    .gridProbe("logDisclosure", area: "deps")
            }
            .padding(Space.margin)
            .gridArea("deps", inset: Space.margin)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $deps.showAegisubGuide) {
            AegisubSetupSheet()
                .environment(model)
        }
        .sheet(isPresented: $deps.showOpusencGuide) {
            OpusencSetupSheet()
                .environment(model)
        }
    }

    private var summaryHeader: some View {
        let deps = model.dependencies
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: deps.allRequiredReady ? "checkmark.seal.fill" : "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(deps.allRequiredReady ? Surfaces.statusSuccess : Surfaces.statusWarning)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(deps.allRequiredReady ? "All Required Dependencies Ready" : "Setup Required")
                        .font(.headline)
                    if let active = deps.activeTaskDescription {
                        HStack(spacing: Space.sm) {
                            ProgressView().controlSize(.small)
                            Text(active)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(
                            deps.allRequiredReady
                                ? "Managed tools live under ~/Library/Application Support/Sushi.GS/."
                                : "Install uv, managed Python 3.13, sushi-batch, and native Apple Silicon FFmpeg in one click — no Terminal or Homebrew required."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Space.sm) {
                if !deps.allRequiredReady {
                    Button("Install Required Dependencies") {
                        Task { await deps.installAllRequired(config: model.config) }
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(deps.isBusy)
                    .help("Download and configure uv, Python 3.13, sushi-batch, FFmpeg, and FFprobe")
                }

                Button("Refresh & Verify All", systemImage: "arrow.clockwise") {
                    Task { await deps.refreshAll(config: model.config, checkRemoteUpdates: true) }
                }
                .fixedSize()
                .disabled(deps.isBusy)
                .help("Re-check all installed tools and query PyPI for sushi-batch updates (Option-Command-R)")

                Spacer()
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

    private func dependencySection(title: String, subtitle: String, records: [DependencyRecord]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    DependencyRowView(record: record)
                    if index < records.count - 1 {
                        Divider().padding(.leading, Space.lg)
                    }
                }
            }
            .background(Surfaces.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Surfaces.hairline, lineWidth: 1)
            )
        }
    }

    private var installLogDisclosure: some View {
        @Bindable var deps = model.dependencies
        return DisclosureGroup("Installer Output (\(deps.installLogs.count) lines)", isExpanded: $deps.showInstallLog) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text("Live output from uv, downloads, and compatibility self-checks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(deps.installLogs.joined(separator: "\n"), forType: .string)
                    }
                    .controlSize(.small)
                    .disabled(deps.installLogs.isEmpty)
                    .hoverDescription("Copy installer output to the clipboard")

                    Button("Clear") {
                        deps.clearLogs()
                    }
                    .controlSize(.small)
                    .disabled(deps.installLogs.isEmpty)
                    .hoverDescription("Clear the installer log")
                }

                if deps.installLogs.isEmpty {
                    Text("No installer activity yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, Space.sm)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(deps.installLogs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(Space.sm)
                    }
                    .frame(height: 180)
                    .background(.background, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .strokeBorder(Surfaces.hairline, lineWidth: 1)
                    )
                }
            }
            .padding(.top, Space.sm)
        }
        .padding(Space.lg)
        .background(Surfaces.card, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Surfaces.hairline, lineWidth: 1)
        )
    }
}

private struct DependencyRowView: View {
    @Environment(AppModel.self) private var model
    let record: DependencyRecord

    var body: some View {
        let deps = model.dependencies
        HStack(alignment: .center, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    Text(record.id.displayName)
                        .font(.body.weight(.medium))
                    statusPill
                    if let ver = record.version, record.state.isReady {
                        Text(ver)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(record.detail.isEmpty ? record.id.unlocksSummary : record.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let path = record.resolvedPath {
                    let displayPath = (path as NSString).abbreviatingWithTildeInPath
                    HStack(spacing: Space.xs) {
                        Text(displayPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(displayPath)
                        Button("Reveal", systemImage: "arrow.up.right.square") {
                            model.revealInFinder(path)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Reveal binary in Finder")
                    }
                }
            }

            Spacer()

            HStack(spacing: Space.sm) {
                primaryActionButton(deps: deps)

                Menu {
                    if record.id != .aegisubCLI {
                        Button("Reinstall") {
                            Task { await deps.installOrUpdate(record.id, config: model.config, reinstall: true) }
                        }
                    }
                    if deps.hasHomebrew, [.ffmpeg, .ffprobe, .mkvmerge, .opusenc].contains(record.id) {
                        Button("Install via Homebrew") {
                            Task { await deps.installOrUpdate(record.id, config: model.config, preferHomebrew: true) }
                        }
                    }
                    if let execKey = record.id.executableName {
                        Button("Choose Custom Binary…") {
                            model.pickBinaryOverride(for: record.id)
                        }
                        if model.config.binaryOverrides[execKey] != nil {
                            Button("Clear Custom Path", role: .destructive) {
                                model.config.binaryOverrides.removeValue(forKey: execKey)
                                Task { await deps.refreshAll(config: model.config, checkRemoteUpdates: false) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(deps.isBusy)
                .help("More install and binary path options")
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    @ViewBuilder
    private func primaryActionButton(deps: DependencyManager) -> some View {
        switch record.state {
        case .installing:
            ProgressView().controlSize(.small)
        case .updateAvailable:
            Button("Update") {
                Task { await deps.installOrUpdate(record.id, config: model.config) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(deps.isBusy)
            .hoverDescription("Update \(record.id.displayName) to the latest version")
        case .installed:
            if record.id == .sushiBatch {
                Button("Check / Update") {
                    Task { await deps.installOrUpdate(.sushiBatch, config: model.config) }
                }
                .controlSize(.small)
                .disabled(deps.isBusy)
                .hoverDescription("Check PyPI or GitHub and update sushi-batch & sushi-sub-next")
            } else {
                Button("Reinstall") {
                    Task { await deps.installOrUpdate(record.id, config: model.config, reinstall: true) }
                }
                .controlSize(.small)
                .disabled(deps.isBusy)
                .hoverDescription("Reinstall \(record.id.displayName)")
            }
        case .missing, .failed, .checking:
            if record.id == .aegisubCLI {
                Button("Setup Guide…") {
                    deps.showAegisubGuide = true
                }
                .controlSize(.small)
                .disabled(deps.isBusy)
                .hoverDescription("Show instructions to build or select aegisub-cli on Apple Silicon")
            } else {
                Button("Install") {
                    Task { await deps.installOrUpdate(record.id, config: model.config) }
                }
                .controlSize(.small)
                .disabled(deps.isBusy)
                .hoverDescription("Install \(record.id.displayName) into Application Support")
            }
        }
    }

    private var statusPill: some View {
        let color: Color
        let symbol: String
        switch record.state {
        case .installed:
            color = Surfaces.statusSuccess
            symbol = "checkmark.circle.fill"
        case .updateAvailable:
            color = Surfaces.statusRunning
            symbol = "arrow.down.circle.fill"
        case .installing, .checking:
            color = Surfaces.statusRunning
            symbol = "arrow.trianglehead.2.clockwise"
        case .missing:
            color = record.id.isRequired ? Surfaces.statusWarning : .secondary
            symbol = record.id.isRequired ? "exclamationmark.triangle.fill" : "minus.circle"
        case .failed:
            color = Surfaces.statusError
            symbol = "xmark.octagon.fill"
        }

        return Label(record.state.badgeText, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct AegisubSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let buildCommand = """
    brew install meson ninja icu4c boost ffms2
    git clone https://github.com/Myaamori/aegisub-cli.git
    cd aegisub-cli && meson setup --buildtype=release builddir
    ninja -C builddir src/aegisub-cli
    """

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Label("Aegisub-CLI Setup (Optional)", systemImage: "terminal")
                .font(.title3.weight(.semibold))

            Text("Upstream Myaamori/aegisub-cli only publishes prebuilt Windows binaries — no official Apple Silicon binary is distributed yet. Subtitle retiming and MKV merging work completely without it; only resolution resampling before merge requires aegisub-cli.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack {
                    Text("Build from source on Apple Silicon")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Commands") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(buildCommand, forType: .string)
                    }
                    .controlSize(.small)
                }

                Text(buildCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Surfaces.card, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }

            HStack {
                Button("Select Built aegisub-cli Binary…") {
                    model.pickBinaryOverride(for: .aegisubCLI)
                    dismiss()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
        .noInitialFocus()
    }
}

private struct OpusencSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Label("opusenc Setup (Optional)", systemImage: "waveform")
                .font(.title3.weight(.semibold))

            Text("Opus audio re-encoding already works out of the box via FFmpeg's built-in libopus encoder. If you specifically prefer Xiph's standalone opusenc encoder, install Homebrew and run:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("brew install opus-tools")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install opus-tools", forType: .string)
                }
                .controlSize(.small)
            }
            .padding(Space.md)
            .background(Surfaces.card, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))

            HStack {
                Button("Select Custom opusenc Binary…") {
                    model.pickBinaryOverride(for: .opusenc)
                    dismiss()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
        .noInitialFocus()
    }
}
