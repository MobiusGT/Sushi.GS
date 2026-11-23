import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Snapshot mode for visual and layout verification (`tools/snap.sh`).
enum Snapshot {
    static func runIfRequested(model: AppModel, openSettings: OpenSettingsAction, openWindow: OpenWindowAction) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty else { return }
        guard model.paths.isOverridden else {
            print("SNAPSHOT refused: set APP_STORE to a folder in /tmp")
            NSApp.terminate(nil)
            return
        }

        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        Task {
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Snapshots" as CFString,
                &awake
            )

            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.5))

            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for page in SidebarDestination.allCases where only?.contains(page.rawValue) ?? true {
                    model.sidebar = page
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/\(page.rawValue)-\(mode).png")
                }
            }

            if only == nil || only?.contains("settings") == true {
                let main = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
                openSettings()
                try? await Task.sleep(for: .seconds(1.0))
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    for tab in SettingsTab.allCases {
                        model.settingsTab = tab
                        try? await Task.sleep(for: .seconds(0.7))
                        let settings = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet }
                        capture(to: "\(dir)/settings-\(tab.rawValue)-\(mode).png", window: settings)
                    }
                }
            }

            if only == nil || only?.contains("about") == true {
                openWindow(id: "about")
                try? await Task.sleep(for: .seconds(0.8))
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    try? await Task.sleep(for: .seconds(0.5))
                    let aboutWin = NSApp.windows.first { $0.isVisible && $0.title.contains("About") }
                    capture(to: "\(dir)/about-\(mode).png", window: aboutWin)
                }
            }

            print("SNAPSHOT done \(dir)")
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            NSApp.terminate(nil)
        }
    }

    private static func capture(to path: String, window: NSWindow? = nil) {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window = window ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            print("SNAPSHOT no window")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Thread.sleep(forTimeInterval: 0.25)
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)

        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission)")
        }
    }
}
