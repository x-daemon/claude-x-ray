import Foundation
import XRayCore

enum SubscriptionPlan: String, CaseIterable, Identifiable, Codable {
    case pro, max5x, max20x, api

    var id: Self { self }

    var title: String {
        switch self {
        case .pro: return "Pro"
        case .max5x: return "Max 5×"
        case .max20x: return "Max 20×"
        case .api: return "API (оплата за токены)"
        }
    }

    var isSubscription: Bool { self != .api }

    /// Label for dollar figures: on a subscription they are an API-equivalent, not a charge.
    var costLabel: String { isSubscription ? "API-эквивалент" : "Стоимость" }
}

/// Persists user settings: data folders and plan in UserDefaults, prices as JSON in Application Support.
struct SettingsStore {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let directories = "dataDirectories"
        static let plan = "subscriptionPlan"
    }

    var directories: [URL]? {
        get {
            (defaults.array(forKey: Key.directories) as? [String])?.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        nonmutating set {
            defaults.set(newValue?.map(\.path), forKey: Key.directories)
        }
    }

    var plan: SubscriptionPlan {
        get { SubscriptionPlan(rawValue: defaults.string(forKey: Key.plan) ?? "") ?? .max5x }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.plan) }
    }

    var pricingURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("S2AClaudeXRay", isDirectory: true).appendingPathComponent("pricing.json")
    }

    func loadPricing() -> PricingTable {
        guard let data = try? Data(contentsOf: pricingURL),
              let table = try? JSONDecoder().decode(PricingTable.self, from: data) else {
            return .default
        }
        return table.mergingMissingDefaults()
    }

    func savePricing(_ table: PricingTable) {
        let url = pricingURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(table).write(to: url, options: .atomic)
        } catch {
            NSLog("S2A Claude X-Ray: failed to save pricing: \(error)")
        }
    }
}
