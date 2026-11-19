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

/// Launched by `AppEntry` (which also handles `--statusline`).
struct S2AClaudeXRayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.s2a.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.auto.rawValue
    /// Read so that a new language rebuilds the windows; AppLanguage.save has applied it already.
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system

    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .auto }
    /// Rebuilds a window's views when the theme or the language changes.
    private var viewID: String { "\(themeRaw)|\(languageRaw)" }

    var body: some Scene {
        Window("S2A Claude X-Ray", id: "main") {
            RootView()
                .environment(model)
                .environment(\.locale, L10n.locale)
                .frame(minWidth: 960, minHeight: 620)
                .themedWindow(appearance: appearance)
                .id(viewID)
        }
        .defaultSize(width: 1220, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L("Обновить данные")) {
                    Task { await model.rescan() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(L("Пересканировать всё")) {
                    Task { await model.fullRescan() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button(L("Импортировать лог сессии…")) {
                    TranscriptImportPanel.run(model: model)
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .environment(\.locale, L10n.locale)
                .themedWindow(appearance: appearance)
                .id(viewID)
        } label: {
            MenuBarLabel(model: model)
                .id(viewID)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, L10n.locale)
                .themedWindow(appearance: appearance)
                .id(viewID)
        }
    }
}

/// Menu bar item: icon plus the current 5-hour window's API-equivalent.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let state = model.liveStatus?.state
        HStack(spacing: 4) {
            Image(systemName: state.map { $0.isActive ? TraceStyle.icon(for: $0) : "waveform.path.ecg" } ?? "waveform.path.ecg")
            Text(model.menuBarTitle).monospacedDigit()
        }
    }
}
