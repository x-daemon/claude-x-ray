import Foundation

/// Model families, used for price fallbacks, grouping and stable chart colors.
public enum ModelFamily: String, CaseIterable, Sendable, Codable {
    case opus, sonnet, haiku, fable, mythos, other

    public var title: String {
        switch self {
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        case .fable: return "Fable"
        case .mythos: return "Mythos"
        case .other: return "Другие"
        }
    }

    /// Price entry used when a model id of this family has no exact entry.
    public var referencePrefix: String? {
        switch self {
        case .opus: return "claude-opus-5-5"
        case .sonnet: return "claude-sonnet-5-5"
        case .haiku: return "claude-haiku-5-5"
        case .fable: return "claude-fable-5-2"
        case .mythos: return "claude-mythos-5-2"
        case .other: return nil
        }
    }

    /// Top-tier families, the first candidates for a what-if on a cheaper model.
    public var isTopTier: Bool { self == .opus || self == .fable || self == .mythos }
}

public enum ModelCatalog {
    public static func family(of model: String) -> ModelFamily {
        let id = model.lowercased()
        for family in [ModelFamily.mythos, .fable, .opus, .sonnet, .haiku] where id.contains(family.rawValue) {
            return family
        }
        return .other
    }

    /// Context window in tokens. Current models have 1M; Haiku 4.5 and older models 200K.
    public static func contextWindow(for model: String) -> Int {
        if model.lowercased().contains("[1m]") { return 1_000_000 }
        let id = PricingTable.normalize(model)
        let oneMillion = [
            "claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7",
            "claude-opus-4-6", "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-5-5",
        ]
        return oneMillion.contains { id.hasPrefix($0) } ? 1_000_000 : 200_000
    }

    /// Human-readable name: `claude-opus-5-5` -> `Opus 5.5`, `claude-sonnet-4-5-20250929` -> `Sonnet 4.5`.
    public static func displayName(for model: String) -> String {
        let id = PricingTable.normalize(model)
        guard id.hasPrefix("claude-") else { return model }
        let parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
        guard let name = parts.first else { return model }

        // Version parts are short numbers; a date suffix (8 digits) ends the version.
        var version: [String] = []
        for part in parts.dropFirst() {
            guard part.count <= 2, Int(part) != nil else { break }
            version.append(part)
        }
        // Old ids put the version first: claude-3-5-sonnet.
        if Int(name) != nil {
            let words = parts.filter { Int($0) == nil && $0.count > 2 }
            let numbers = parts.filter { $0.count <= 2 && Int($0) != nil }
            let title = (words.first ?? name).capitalized
            return numbers.isEmpty ? title : "\(title) \(numbers.joined(separator: "."))"
        }
        let title = name.capitalized
        return version.isEmpty ? title : "\(title) \(version.joined(separator: "."))"
    }
}
