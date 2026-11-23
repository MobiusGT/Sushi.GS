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
                        } else if model.sidebar == .batchQueue {
                            Button("Select Folders", systemImage: "folder.badge.plus") {
                                model.openBatchFoldersWorkflow()
                            }
                            .help("Select Source and Target folders for batch pairing (Option-Command-O)")
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
                            .help("Cancel the active operation (Command-Period)")
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
            model.batchJobs.contains(where: \.hasRequiredInputs) && model.dependencies.allRequiredReady
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
            if !model.batchJobs.isEmpty {
                return ("\(model.batchJobs.count)", .secondary)
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
