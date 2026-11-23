import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(SidebarDestination.allCases, selection: $model.sidebar) { destination in
                HStack {
                    Label(destination.title, systemImage: destination.symbol)
                    Spacer()
                    if let badge = sidebarBadge(for: destination) {
                        Text(badge.text)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(badge.color)
                            .padding(.horizontal, Space.xs)
                            .padding(.vertical, 2)
                            .background(badge.color.opacity(0.14), in: Capsule())
                    }
                }
                .tag(destination)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            detailContent
                .navigationTitle("Gas Station Sushi")
                .navigationSubtitle(model.windowSubtitle)
                .toolbar {
                    ToolbarSpacer(.flexible)

                    ToolbarItemGroup {
                        if model.sidebar == .singleEpisode {
                            Button("Open Source", systemImage: "doc.badge.plus") {
                                model.openSingleSourcePanel()
                            }
                            .help("Choose a Source video or audio file (Command-O)")

                            Button("Clear", systemImage: "arrow.counterclockwise") {
                                model.clearSingleEpisode()
                            }
                            .disabled(model.isRunning || !model.singleJob.hasAnyStateToClear)
                            .help("Clear files, status, metrics, warnings, and logs to start fresh (Shift-Command-K)")
                        } else if model.sidebar == .batchQueue {
                            Button("Add Source Folder", systemImage: "folder.badge.plus") {
                                model.pickBatchSourceFolder(replaceExisting: !model.isBatchInQueueStage)
                            }
                            .disabled(model.isRunning)
                            .help("Select a Source folder for Batch Queue (Option-Command-O)")

                            Button("Add Target Folder", systemImage: "sparkles.tv") {
                                model.pickBatchTargetFolder(replaceExisting: !model.isBatchInQueueStage)
                            }
                            .disabled(model.isRunning)
                            .help("Select a Target folder for Batch Queue (Option-Shift-Command-O)")
                        }
                    }

                    ToolbarSpacer(.fixed)

                    ToolbarItemGroup {
                        if model.isRunning {
                            Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                                model.togglePauseQueue()
                            }
                            .help("Pause or resume batch queue (Option-Command-P)")

                            Button("Cancel", systemImage: "stop.fill") {
                                model.cancelActiveJob()
                            }
                            .disabled(model.isCancelling)
                            .help("Cancel the active operation and clean temporary files (Command-Period)")
                        } else {
                            Button("Run Sync", systemImage: "play.fill") {
                                model.runPrimaryAction()
                            }
                            .disabled(!canRunToolbarAction)
                            .help(toolbarRunHelp)
                        }
                    }
                }
        }
        .inspector(isPresented: $model.showInspector) {
            LogInspectorView()
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem {
                        Button(model.showInspector ? "Hide Log Inspector" : "Show Log Inspector", systemImage: "sidebar.trailing") {
                            model.showInspector.toggle()
                        }
                        .help("Show or hide the Log Inspector (Control-Command-I)")
                    }
                }
        }
        .frame(minWidth: 1020, minHeight: 620)
        .overlay {
            if GridOverlay.enabled {
                GridOverlay()
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.sidebar {
        case .singleEpisode:
            SingleEpisodeView()
        case .batchQueue:
            BatchQueueView()
        case .dependencies:
            DependenciesView()
        }
    }

    private var canRunToolbarAction: Bool {
        switch model.sidebar {
        case .singleEpisode:
            model.singleJob.hasRequiredInputs && model.dependencies.allRequiredReady
        case .batchQueue:
            model.isBatchInQueueStage && model.batchJobs.contains(where: \.hasRequiredInputs) && model.dependencies.allRequiredReady
        case .dependencies:
            !model.dependencies.isBusy && !model.dependencies.allRequiredReady
        }
    }

    private var toolbarRunHelp: String {
        switch model.sidebar {
        case .singleEpisode: "Sync the current episode (Command-R)"
        case .batchQueue: "Start the batch synchronization queue (Command-R)"
        case .dependencies: "Install required dependencies"
        }
    }

    private func sidebarBadge(for dest: SidebarDestination) -> (text: String, color: Color)? {
        switch dest {
        case .singleEpisode:
            if model.singleJob.status == .warned {
                return ("!", Surfaces.statusWarning)
            }
            return nil
        case .batchQueue:
            let warned = model.batchJobs.filter { $0.status == .warned }.count
            if warned > 0 {
                return ("\(warned)!", Surfaces.statusWarning)
            }
            if model.isBatchInQueueStage && !model.batchJobs.isEmpty {
                return ("\(model.batchJobs.count)", .secondary)
            }
            if model.hasStagedSource != model.hasStagedTarget {
                return ("1/2", Palette.accentText)
            }
            return nil
        case .dependencies:
            let missing = model.dependencies.missingRequiredDependencies.count
            if missing > 0 {
                return ("\(missing)", Surfaces.statusWarning)
            }
            return nil
        }
    }
}
