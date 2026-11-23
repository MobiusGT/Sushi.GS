import SwiftUI

/// Settings > Appearance: choose System (with Tamago Gold brand accent on Multicolor) or any accent.
struct AppearanceSettings: View {
    @Bindable private var store = ThemeStore.shared

    var body: some View {
        Section {
            AccentPreview()
                .padding(.vertical, Space.xs)
            LabeledContent("Accent color") {
                VStack(alignment: .trailing, spacing: Space.xs) {
                    HStack(spacing: Space.sm) {
                        ForEach(Theme.all) { theme in
                            AccentSwatch(theme: theme, selected: store.themeID == theme.id) {
                                store.themeID = theme.id
                            }
                        }
                    }
                    Text(store.theme.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Light and dark appearance follow your macOS System Settings.")
        }
    }
}

private struct AccentPreview: View {
    private let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(height: 152)
        .background(.background, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the accent color")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.quaternary).frame(width: 8, height: 8)
                }
            }
            .padding(.leading, Space.xs)
            .padding(.bottom, Space.sm)
            sidebarRow("Single", symbol: "film", selected: true)
            sidebarRow("Batch", symbol: "square.stack.3d.up", selected: false)
            sidebarRow("Tools", symbol: "shippingbox", selected: false)
            Spacer(minLength: 0)
        }
        .padding(Space.sm)
        .frame(width: 128)
        .background(.background.secondary)
    }

    private func sidebarRow(_ title: String, symbol: String, selected: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(selected ? Palette.onAccent : .primary)
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background(
                selected ? Palette.accent : .clear,
                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Gas Station Sushi").font(.headline)
                Spacer()
                Text("Ready").font(.caption).foregroundStyle(Palette.accentText)
            }
            sampleRow("Episode 01 · +0.412s", done: true)
            sampleRow("Episode 02 · Japanese FLAC", done: false, tag: "Queued")
            Spacer(minLength: 0)
            HStack {
                Label("Sync", systemImage: "waveform")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, Space.md)
                    .frame(height: 24)
                    .background(Palette.accent, in: Capsule())
                Spacer()
                Text("Auto Merge").font(.caption).foregroundStyle(.secondary)
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: 28, height: 16)
                    .overlay(alignment: .trailing) {
                        Circle().fill(.white).padding(2)
                            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    }
            }
        }
        .padding(Space.md)
    }

    private func sampleRow(_ title: String, done: Bool, tag: String? = nil) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            Text(title)
                .lineLimit(1)
                .foregroundStyle(done ? .secondary : .primary)
            Spacer()
            if let tag {
                Text(tag)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.accentText)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(Palette.accent.opacity(0.15), in: Capsule())
            }
        }
        .font(.callout)
    }
}

private struct AccentSwatch: View {
    let theme: Theme
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Circle()
                .fill(fill)
                .frame(width: 16, height: 16)
                .overlay {
                    if selected {
                        Circle().fill(theme.onAccent).frame(width: 6, height: 6) // grid: ok
                    }
                }
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(theme.name)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: AnyShapeStyle {
        if let tint = theme.tint {
            AnyShapeStyle(tint)
        } else {
            AnyShapeStyle(
                AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                    center: .center
                )
            )
        }
    }
}
