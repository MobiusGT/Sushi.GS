import SwiftUI
import SushiGSKit

struct LogInspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let entries = model.activeLogEntries()
        let warningEntries = entries.filter { $0.severity == .warning }
        let errorCount = entries.filter { $0.severity == .error }.count

        VStack(spacing: 0) {
            // Controls header
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Text("Log Inspector")
                        .font(.headline)
                    Spacer()
                    Button("Copy", systemImage: "document.on.document") {
                        model.copyCurrentLogsToPasteboard()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(entries.isEmpty)
                    .help("Copy visible log lines (Option-Command-C)")

                    Button("Export…", systemImage: "square.and.arrow.up") {
                        model.exportCurrentLogs()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(entries.isEmpty)
                    .help("Export log to a .log file (Shift-Command-E)")
                }

                Picker("Scope", selection: $model.logScope) {
                    ForEach(LogScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                HStack(spacing: Space.xs) {
                    ForEach(LogFilter.allCases) { filter in
                        filterPill(filter, warnings: warningEntries.count, errors: errorCount)
                    }
                    Spacer()
                    if let firstWarn = warningEntries.first {
                        Button {
                            model.highlightedLogID = firstWarn.id
                            model.highlightedLineIndex = firstWarn.lineIndex
                        } label: {
                            Label("Warning", systemImage: "arrow.down.to.line")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .help("Jump to highlighted warning line")
                    }
                }

                HStack(spacing: Space.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter log output…", text: $model.logSearch)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !model.logSearch.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") {
                            model.logSearch = ""
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .background(Surfaces.card, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .strokeBorder(Surfaces.hairline, lineWidth: 1)
                )
            }
            .padding(Space.md)

            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    model.logSearch.isEmpty ? "No Log Output Yet" : "No Matching Lines",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        model.logSearch.isEmpty
                            ? "Live Sushi, FFmpeg, and MKVMerge output streams here when an episode runs."
                            : "Adjust the severity filter or search text."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(entries) { entry in
                                LogLineRow(
                                    entry: entry,
                                    isHighlighted: model.highlightedLogID == entry.id
                                        || (model.highlightedLineIndex != nil && model.highlightedLineIndex == entry.lineIndex)
                                )
                                .id(entry.id)
                            }
                        }
                        .padding(Space.sm)
                    }
                    .onChange(of: model.highlightedLogID) { _, newID in
                        guard let newID else { return }
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    private func filterPill(_ filter: LogFilter, warnings: Int, errors: Int) -> some View {
        let selected = model.logFilter == filter
        let title: String = switch filter {
        case .all: "All"
        case .warnings: warnings > 0 ? "Warnings (\(warnings))" : "Warnings"
        case .errors: errors > 0 ? "Errors (\(errors))" : "Errors"
        }

        return Button(title) {
            model.logFilter = filter
        }
        .buttonStyle(.plain)
        .font(.caption.weight(selected ? .semibold : .regular))
        .foregroundStyle(selected ? Palette.onAccent : .primary)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(
            selected ? Palette.accent : Surfaces.card,
            in: Capsule()
        )
    }
}

private struct LogLineRow: View {
    let entry: LogEntry
    let isHighlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            Text("\(entry.lineIndex + 1)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)

            Text(entry.line)
                .font(.caption.monospaced())
                .foregroundStyle(lineColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 2)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        .overlay(alignment: .leading) {
            if entry.severity != .info {
                Capsule()
                    .fill(entry.severity == .error ? Surfaces.statusError : Surfaces.statusWarning)
                    .frame(width: 2)
                    .padding(.vertical, 2)
            }
        }
    }

    private var lineColor: Color {
        switch entry.severity {
        case .info: .primary
        case .warning: Surfaces.statusWarning
        case .error: Surfaces.statusError
        }
    }

    private var rowBackground: Color {
        if isHighlighted {
            return Surfaces.statusWarning.opacity(0.28)
        }
        switch entry.severity {
        case .info: return .clear
        case .warning: return Surfaces.statusWarning.opacity(0.10)
        case .error: return Surfaces.statusError.opacity(0.10)
        }
    }
}
