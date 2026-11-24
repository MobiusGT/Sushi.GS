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
            .navigationSplitViewColumnWidth(min: 180, ideal: 204, max: 256)
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
                        } else if model.sidebar == .autoBatch {
                            Button("Add Source Media Folder", systemImage: "folder.badge.plus") {
                                model.pickBatchSourceFolder(replaceExisting: !model.isBatchInQueueStage)
                            }
                            .disabled(model.isRunning)
                            .help("Add a Source Media Folder for Auto Batch (Option-Command-O)")

                            Button("Add Target Media Folder", systemImage: "sparkles.tv") {
                                model.pickBatchTargetFolder(replaceExisting: !model.isBatchInQueueStage)
                            }
                            .disabled(model.isRunning)
                            .help("Add a Target Media Folder for Auto Batch (Option-Shift-Command-O)")

                            Button("Add External Subtitle Folder", systemImage: "captions.bubble") {
                                model.pickBatchSubtitleFolder(replaceExisting: !model.isBatchInQueueStage)
                            }
                            .disabled(model.isRunning)
                            .help("Add an External Subtitle Folder for Auto Batch (Control-Option-Command-O)")
                        } else if model.sidebar == .manualBatch {
                            Button("Choose Folder", systemImage: "folder") {
                                model.chooseManualBrowserFolder()
                            }
                            .help("Choose a root folder for the Manual Batch File Browser")

                            Button("Clear All", systemImage: "arrow.counterclockwise") {
                                model.requestClearManualBatch()
                            }
                            .disabled(model.isRunning || model.manualColumns.isEmpty)
                            .help("Clear all columns in Manual Batch")
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
                .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
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
        .frame(minWidth: 1020, minHeight: 640)
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
        case .autoBatch:
            BatchQueueView()
        case .manualBatch:
            ManualBatchView()
        case .dependencies:
            DependenciesView()
        }
    }

    private var canRunToolbarAction: Bool {
        switch model.sidebar {
        case .singleEpisode:
            model.singleJob.hasRequiredInputs && model.dependencies.allRequiredReady
        case .autoBatch:
            model.isBatchInQueueStage
                && model.batchJobs.contains(where: \.hasPairedFiles)
                && model.dependencies.allRequiredReady
        case .manualBatch:
            model.manualJobs.contains(where: \.hasPairedFiles) && model.dependencies.allRequiredReady
        case .dependencies:
            !model.dependencies.isBusy && !model.dependencies.allRequiredReady
        }
    }

    private var toolbarRunHelp: String {
        switch model.sidebar {
        case .singleEpisode: "Sync the current episode (Command-R)"
        case .autoBatch: "Start the Auto Batch synchronization queue (Command-R)"
        case .manualBatch: "Start the Manual Batch synchronization queue (Command-R)"
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
        case .autoBatch:
            let warned = model.batchJobs.filter { $0.status == .warned }.count
            if warned > 0 {
                return ("\(warned)!", Surfaces.statusWarning)
            }
            if model.isBatchInQueueStage && !model.batchJobs.isEmpty {
                return ("\(model.batchJobs.count)", .secondary)
            }
            let progress = model.stagedFolderProgress
            if progress.ready > 0 && progress.ready < progress.total {
                return ("\(progress.ready)/\(progress.total)", Palette.accentText)
            }
            return nil
        case .manualBatch:
            let warned = model.manualJobs.filter { $0.status == .warned }.count
            if warned > 0 {
                return ("\(warned)!", Surfaces.statusWarning)
            }
            let total = model.manualColumns.rowCount
            if total > 0 {
                let complete = model.manualColumns.completeRowCount
                if complete == total {
                    return ("\(complete)", .secondary)
                }
                return ("\(complete)/\(total)", Surfaces.statusWarning)
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
