import Foundation
import XRayCore

/// The interface language setting, kept in UserDefaults as "system" or a language code.
enum AppLanguage {
    static let storageKey = "appLanguage"
    static let system = "system"

    /// Keys that earlier versions wrote: their users keep the Russian interface they had.
    private static let earlierKeys = ["subscriptionPlan", "dataDirectories", "appTheme", "appAppearance", "receiver.enabled", "receiver.port", "trace.hideContent"]

    /// The stored setting. On the first launch of a version that has it: Russian for people who
    /// used X-Ray before, the system language for new installs.
    static var setting: String {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: storageKey) { return value }
        let value = earlierKeys.contains { defaults.object(forKey: $0) != nil } ? Language.ru.rawValue : system
        defaults.set(value, forKey: storageKey)
        return value
    }

    /// Applies the setting to every text X-Ray shows. `XRAY_SNAPSHOT_LANGUAGE` overrides it for
    /// the snapshot runner.
    static func apply(_ setting: String) {
        L10n.language = L10n.resolve(ProcessInfo.processInfo.environment["XRAY_SNAPSHOT_LANGUAGE"] ?? setting)
    }

    /// Saves a new setting. macOS's own menu items (Hide, Quit, Window…) follow it from the next
    /// launch, through the app's AppleLanguages; X-Ray's own texts change at once.
    static func save(_ setting: String) {
        let defaults = UserDefaults.standard
        defaults.set(setting, forKey: storageKey)
        if let language = Language(rawValue: setting) {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
        apply(setting)
    }
}
