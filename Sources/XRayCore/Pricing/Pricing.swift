import Foundation

/// Per-model API list prices, USD per million tokens.
public struct ModelPrice: Codable, Hashable, Sendable, Identifiable {
    /// Model id prefix this price applies to, e.g. `claude-opus-5-5`.
    /// The longest matching prefix wins, so `claude-opus-5-5` beats `claude-opus-5`.
    public var modelPrefix: String
    public var displayName: String
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    /// Prompt size (fresh input + cache) above which `longContextMultiplier` applies to every rate.
    public var longContextThreshold: Int?
    public var longContextMultiplier: Double?
    /// Free-form note shown in the price editor (source, what to verify).
    public var note: String?

    public var id: String { modelPrefix }

    public init(
        modelPrefix: String,
        displayName: String,
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheWrite5m: Double? = nil,
        cacheWrite1h: Double? = nil,
        longContextThreshold: Int? = nil,
        longContextMultiplier: Double? = nil,
        note: String? = nil
    ) {
        self.modelPrefix = modelPrefix
        self.displayName = displayName
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        // Standard multipliers: 5-minute writes 1.25x input, 1-hour writes 2x input.
        self.cacheWrite5m = cacheWrite5m ?? input * 1.25
        self.cacheWrite1h = cacheWrite1h ?? input * 2
        self.longContextThreshold = longContextThreshold
        self.longContextMultiplier = longContextMultiplier
        self.note = note
    }
}

/// Dollar cost of one request (or a sum), split by what was billed.
public struct CostBreakdown: Codable, Hashable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var webSearch: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, webSearch: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.webSearch = webSearch
    }

    public static let zero = CostBreakdown()

    public var total: Double { input + output + cacheRead + cacheWrite + webSearch }

    public static func + (lhs: CostBreakdown, rhs: CostBreakdown) -> CostBreakdown {
        CostBreakdown(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            webSearch: lhs.webSearch + rhs.webSearch
        )
    }

    public static func += (lhs: inout CostBreakdown, rhs: CostBreakdown) {
        lhs = lhs + rhs
    }
}

/// How a model id was matched to a price.
public struct PriceMatch: Hashable, Sendable {
    public let price: ModelPrice?
    /// `true` when no exact prefix matched and the price was borrowed from the model family.
    public let isEstimated: Bool

    public init(price: ModelPrice?, isEstimated: Bool) {
        self.price = price
        self.isEstimated = isEstimated
    }
}

/// A usage event together with its API-equivalent cost.
public struct PricedEvent: Hashable, Sendable, Identifiable {
    public let event: UsageEvent
    public let cost: CostBreakdown
    /// Price came from a family fallback or is unknown (cost 0).
    public let isEstimated: Bool

    public init(event: UsageEvent, cost: CostBreakdown, isEstimated: Bool) {
        self.event = event
        self.cost = cost
        self.isEstimated = isEstimated
    }

    public var id: String { event.id }
}

/// Editable price list. The defaults are the public API list prices; for a
/// Pro/Max subscription they express the *API-equivalent* value of the usage,
/// not money that is charged.
public struct PricingTable: Codable, Hashable, Sendable {
    public var models: [ModelPrice]
    /// Fast mode (`speed: "fast"`) multiplier applied to every rate.
    public var fastModeMultiplier: Double
    /// USD per 1,000 server-side web searches.
    public var webSearchPer1K: Double
    /// Date the defaults were taken from, shown in the UI.
    public var sourceNote: String

    public init(models: [ModelPrice], fastModeMultiplier: Double = 2, webSearchPer1K: Double = 10, sourceNote: String = "") {
        self.models = models
        self.fastModeMultiplier = fastModeMultiplier
        self.webSearchPer1K = webSearchPer1K
        self.sourceNote = sourceNote
    }

    // MARK: Matching

    /// Normalises provider-specific ids: `us.anthropic.claude-opus-4-8-v1:0`,
    /// `claude-opus-4-5@20251101`, `claude-opus-5-5[1m]` -> plain `claude-...` ids.
    public static func normalize(_ model: String) -> String {
        var id = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let range = id.range(of: "claude-") {
            id = String(id[range.lowerBound...])
        }
        for separator in ["@", "[", ":"] {
            if let range = id.range(of: separator) {
                id = String(id[..<range.lowerBound])
            }
        }
        if id.hasSuffix("-v1") || id.hasSuffix("-v2") {
            id = String(id.dropLast(3))
        }
        return id
    }

    public func match(model: String) -> PriceMatch {
        let id = Self.normalize(model)
        var best: ModelPrice?
        for price in models {
            let prefix = price.modelPrefix.lowercased()
            guard id.hasPrefix(prefix) else { continue }
            let rest = id.dropFirst(prefix.count)
            guard rest.isEmpty || rest.hasPrefix("-") else { continue }
            if prefix.count > (best?.modelPrefix.count ?? -1) {
                best = price
            }
        }
        if let best {
            return PriceMatch(price: best, isEstimated: false)
        }

        // Unknown version of a known family: borrow the family's current price.
        let family = ModelCatalog.family(of: id)
        if let fallbackPrefix = family.referencePrefix,
           let fallback = models.first(where: { $0.modelPrefix == fallbackPrefix }) {
            return PriceMatch(price: fallback, isEstimated: true)
        }
        return PriceMatch(price: nil, isEstimated: true)
    }

    // MARK: Costing

    public func cost(of event: UsageEvent, price: ModelPrice?) -> CostBreakdown {
        let searchCost = Double(event.webSearchRequests) / 1000 * webSearchPer1K
        guard let price else { return CostBreakdown(webSearch: searchCost) }

        var multiplier = event.isFastMode ? fastModeMultiplier : 1
        if let threshold = price.longContextThreshold,
           let longMultiplier = price.longContextMultiplier,
           event.tokens.contextTokens > threshold {
            multiplier *= longMultiplier
        }
        let perToken = multiplier / 1_000_000
        let t = event.tokens
        return CostBreakdown(
            input: Double(t.input) * price.input * perToken,
            output: Double(t.output) * price.output * perToken,
            cacheRead: Double(t.cacheRead) * price.cacheRead * perToken,
            cacheWrite: (Double(t.cacheWrite5m) * price.cacheWrite5m + Double(t.cacheWrite1h) * price.cacheWrite1h) * perToken,
            webSearch: searchCost
        )
    }

    public func cost(of event: UsageEvent) -> CostBreakdown {
        cost(of: event, price: match(model: event.model).price)
    }

    /// Prices a batch of events, matching each distinct model id once.
    public func price(_ events: [UsageEvent]) -> [PricedEvent] {
        var cache: [String: PriceMatch] = [:]
        return events.map { event in
            let match: PriceMatch
            if let cached = cache[event.model] {
                match = cached
            } else {
                match = self.match(model: event.model)
                cache[event.model] = match
            }
            return PricedEvent(event: event, cost: cost(of: event, price: match.price), isEstimated: match.isEstimated)
        }
    }

    /// Re-costs events as if they had run on another model (for what-if estimates).
    public func cost(of events: [PricedEvent], asModel modelPrefix: String) -> Double? {
        guard let target = models.first(where: { $0.modelPrefix == modelPrefix }) else { return nil }
        return events.reduce(0) { $0 + cost(of: $1.event, price: target).total }
    }

    /// Adds default entries that a saved table does not have yet (new models after an app update).
    public func mergingMissingDefaults(from defaults: PricingTable = .default) -> PricingTable {
        var merged = self
        let known = Set(models.map(\.modelPrefix))
        merged.models.append(contentsOf: defaults.models.filter { !known.contains($0.modelPrefix) })
        return merged
    }
}

extension PricingTable {
    /// Public API list prices, USD per million tokens (as of 2026-11-03).
    /// Cache writes follow the standard 1.25x (5 min) / 2x (1 h) input multipliers.
    /// Verify against https://platform.claude.com/docs/en/about-claude/pricing — prices change.
    public static let `default` = PricingTable(
        models: [
            ModelPrice(modelPrefix: "claude-fable-5-2", displayName: "Fable 5.2", input: 8, output: 40, cacheRead: 0.20),
            ModelPrice(modelPrefix: "claude-mythos-5-2", displayName: "Mythos 5.2", input: 8, output: 40, cacheRead: 0.20),
            ModelPrice(modelPrefix: "claude-fable-5-1", displayName: "Fable 5.1", input: 10, output: 50, cacheRead: 0.25),
            ModelPrice(modelPrefix: "claude-mythos-5-1", displayName: "Mythos 5.1", input: 10, output: 50, cacheRead: 0.25),
            ModelPrice(modelPrefix: "claude-fable-5", displayName: "Fable 5", input: 10, output: 50, cacheRead: 1.00),
            ModelPrice(modelPrefix: "claude-mythos-5", displayName: "Mythos 5", input: 10, output: 50, cacheRead: 1.00),
            ModelPrice(modelPrefix: "claude-opus-5-5", displayName: "Opus 5.5", input: 4, output: 20, cacheRead: 0.20),
            ModelPrice(modelPrefix: "claude-opus-5", displayName: "Opus 5", input: 5, output: 25, cacheRead: 0.50),
            ModelPrice(modelPrefix: "claude-opus-4-8", displayName: "Opus 4.8", input: 5, output: 25, cacheRead: 0.50),
            ModelPrice(modelPrefix: "claude-opus-4-7", displayName: "Opus 4.7", input: 5, output: 25, cacheRead: 0.50),
            ModelPrice(modelPrefix: "claude-opus-4-6", displayName: "Opus 4.6", input: 5, output: 25, cacheRead: 0.50),
            ModelPrice(modelPrefix: "claude-sonnet-5-5", displayName: "Sonnet 5.5", input: 2, output: 10, cacheRead: 0.10),
            ModelPrice(modelPrefix: "claude-sonnet-5", displayName: "Sonnet 5", input: 2, output: 10, cacheRead: 0.20),
            ModelPrice(modelPrefix: "claude-sonnet-4-6", displayName: "Sonnet 4.6", input: 3, output: 15, cacheRead: 0.30),
            ModelPrice(
                modelPrefix: "claude-haiku-5-5", displayName: "Haiku 5.5", input: 0.10, output: 0.50, cacheRead: 0.01,
                longContextThreshold: 100_000, longContextMultiplier: 5,
                note: L10n.key("Свыше 100K токенов промпта — $0.50 / $2.50. Цена чтения кэша принята как 0.1× — проверьте.")
            ),
            ModelPrice(modelPrefix: "claude-haiku-4-5", displayName: "Haiku 4.5", input: 1, output: 5, cacheRead: 0.10),
        ],
        fastModeMultiplier: 2,
        webSearchPer1K: 10,
        sourceNote: L10n.key("Прайс-лист API на 2026-11-03")
    )
}
