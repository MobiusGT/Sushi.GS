import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            let code = SelfTest.runAll()
            fflush(stdout)
            exit(code)
        }
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct SushiGSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @ObservedObject private var menuState = MenuState.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        WindowGroup("Gas Station Sushi") {
            ContentView()
                .environment(model)
                .themed()
                .task {
                    Snapshot.runIfRequested(model: model, openSettings: openSettings, openWindow: openWindow)
                    await model.bootstrapOnLaunch()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            InspectorCommands()

            CommandGroup(replacing: .appInfo) {
                Button("About Gas Station Sushi") {
                    openWindow(id: "about")
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Source File…") {
                    model.openSingleSourcePanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Open Target File…") {
                    model.openSingleTargetPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Add Source Media Folder…") {
                    model.pickBatchSourceFolder(replaceExisting: !model.isBatchInQueueStage)
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(menuState.isRunning)

                Button("Add Target Media Folder…") {
                    model.pickBatchTargetFolder(replaceExisting: !model.isBatchInQueueStage)
                }
                .keyboardShortcut("o", modifiers: [.command, .option, .shift])
                .disabled(menuState.isRunning)

                Button("Add External Subtitle Folder…") {
                    model.pickBatchSubtitleFolder(replaceExisting: !model.isBatchInQueueStage)
                }
                .keyboardShortcut("o", modifiers: [.command, .option, .control])
                .disabled(menuState.isRunning)

                Divider()

                Button("Export Log…") {
                    model.exportCurrentLogs()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!menuState.hasLogs)
            }

            CommandGroup(after: .pasteboard) {
                Button("Copy Visible Logs") {
                    model.copyCurrentLogsToPasteboard()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!menuState.hasLogs)
            }

            CommandGroup(after: .sidebar) {
                Divider()
                Button("Single Episode") { model.sidebar = .singleEpisode }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Auto Batch") { model.sidebar = .autoBatch }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Manual Batch") { model.sidebar = .manualBatch }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Dependencies") { model.sidebar = .dependencies }
                    .keyboardShortcut("4", modifiers: [.command])
            }

            CommandMenu("Queue") {
                Button("Run Sync") {
                    model.runPrimaryAction()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!menuState.canRun)

                Button(menuState.isPaused ? "Resume Queue" : "Pause Queue") {
                    model.togglePauseQueue()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!menuState.isRunning)

                Button("Cancel Active Job") {
                    model.cancelActiveJob()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!menuState.isRunning)

                Divider()

                Button(menuState.unverifiedBatchCount > 0 ? "Verify All Pairs (\(menuState.unverifiedBatchCount))" : "Verify All Pairs") {
                    model.verifyAllBatchPairs()
                }
                .disabled(menuState.unverifiedBatchCount == 0)

                Button("Retry Failed or Warned") {
                    model.retryFailedOrWarned()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!menuState.canRetry)

                Button("Merge Completed MKVs") {
                    model.mergeCompletedJobs()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!menuState.canMerge)

                Divider()

                Button("Clear Single Episode") {
                    model.clearSingleEpisode()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!menuState.canClearSingle)

                Button("Clear Auto Batch…") {
                    model.requestClearBatchQueue()
                }
                .disabled(!menuState.canClearBatch)

                Button("Clear Manual Batch…") {
                    model.requestClearManualBatch()
                }
                .disabled(!menuState.canClearManualBatch)

                Divider()

                Button("Refresh Dependencies") {
                    Task { await model.dependencies.refreshAll(config: model.config, checkRemoteUpdates: true) }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .help) {
                Link("Gas Station Sushi on GitHub", destination: URL(string: "https://github.com/MobiusGT/Sushi.GS")!)
                Link("Report an Issue…", destination: URL(string: "https://github.com/MobiusGT/Sushi.GS/issues")!)
                Divider()
                Link("C1fer/sushi-batch Documentation", destination: URL(string: "https://github.com/C1fer/sushi-batch")!)
                Link("C1fer/sushi-next Documentation", destination: URL(string: "https://github.com/C1fer/sushi-next")!)
            }
        }

        Window("About Gas Station Sushi", id: "about") {
            AboutView()
                .themed()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}
