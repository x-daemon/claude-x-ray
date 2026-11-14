import AppKit
import SwiftUI
import XRayCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Built with SwiftPM the binary has no bundle Info.plist when run directly; make it a regular Dock app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Closing the window keeps the menu bar monitor running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct S2AClaudeXRayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("S2A Claude X-Ray", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1220, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Обновить данные") {
                    Task { await model.rescan() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Пересканировать всё") {
                    Task { await model.fullRescan() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Menu bar item: icon plus the current 5-hour window's API-equivalent.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg")
            Text(model.menuBarTitle).monospacedDigit()
        }
    }
}
