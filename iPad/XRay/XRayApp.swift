import SwiftUI
import XRayCore

/// X-Ray for iPad: the same screens as on the Mac, from copies of the logs of the user's
/// computers (Mac or Windows), which X-Ray there serves read-only.
@main
struct XRayApp: App {
    @State private var model: AppModel
    @State private var sync: DesktopSync
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.s2a.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.auto.rawValue
    /// Read so that a new language rebuilds the screens; AppLanguage.save has applied it already.
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system
    @Environment(\.scenePhase) private var scenePhase
    /// A connect link opened from the camera, waiting for the user to confirm it.
    @State private var pendingLink: ViewerLink?
    @State private var badLink = false

    init() {
        AppLanguage.apply(AppLanguage.setting)
        let model = AppModel()
        let sync = DesktopSync(model: model)
        _model = State(initialValue: model)
        _sync = State(initialValue: sync)
        if IPadSnapshots.isRequested {
            Task { @MainActor in await IPadSnapshots.run(model: model, sync: sync) }
        }
    }

    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .auto }
    /// Rebuilds the screens when the theme or the language changes.
    private var viewID: String { "\(themeRaw)|\(languageRaw)" }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(sync)
                .environment(\.locale, L10n.locale)
                .themedWindow(appearance: appearance)
                .id(viewID)
                .onOpenURL { url in
                    if let link = ViewerLink(url: url) {
                        pendingLink = link
                    } else {
                        badLink = true
                    }
                }
                .alert(
                    L("Подключить компьютер?"),
                    isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
                    presenting: pendingLink
                ) { link in
                    Button(L("Подключить")) {
                        sync.add(link)
                        model.selection = .live
                    }
                    Button(L("Отмена"), role: .cancel) {}
                } message: { link in
                    Text(L("X-Ray на iPad будет читать логи Claude Code с компьютера «\(link.name ?? link.server.host ?? "")» по адресу \(link.server.absoluteString)."))
                }
                .alert(L("Ссылка не подходит"), isPresented: $badLink) {
                    Button(L("Понятно"), role: .cancel) {}
                } message: {
                    Text(L("Откройте ссылку или QR-код из X-Ray на компьютере: «Настройки → iPad»."))
                }
        }
        .onChange(of: scenePhase) { _, phase in
            sync.setActive(phase == .active)
        }
    }
}
