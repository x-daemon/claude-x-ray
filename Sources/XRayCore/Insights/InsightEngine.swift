import Foundation

public enum InsightSeverity: Int, Comparable, Sendable, CaseIterable {
    case good = 0, info = 1, warning = 2, critical = 3

    public static func < (lhs: InsightSeverity, rhs: InsightSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .good: return "Хорошо"
        case .info: return "Совет"
        case .warning: return "Внимание"
        case .critical: return "Критично"
        }
    }
}

/// Whether acting on an insight costs quality.
public enum InsightKind: String, Sendable {
    /// Saves tokens without lowering output quality (caching, context hygiene).
    case freeWin
    /// Trades capability for cost (cheaper model, lower effort) — check quality on your tasks.
    case tradeoff
    /// Information, nothing to change.
    case observation

    public var label: String {
        switch self {
        case .freeWin: return "Без потери качества"
        case .tradeoff: return "Компромисс"
        case .observation: return "Наблюдение"
        }
    }
}

public struct Insight: Identifiable, Hashable, Sendable {
    public let id: String
    public let severity: InsightSeverity
    public let kind: InsightKind
    public let title: String
    /// What the data shows.
    public let detail: String
    /// What to do about it.
    public let recommendation: String?
    /// Key figure, e.g. "38%".
    public let metric: String?
    /// API-equivalent USD that could be saved over the analysed period.
    public let potentialSavings: Double?

    public init(
        id: String,
        severity: InsightSeverity,
        kind: InsightKind,
        title: String,
        detail: String,
        recommendation: String? = nil,
        metric: String? = nil,
        potentialSavings: Double? = nil
    ) {
        self.id = id
        self.severity = severity
        self.kind = kind
        self.title = title
        self.detail = detail
        self.recommendation = recommendation
        self.metric = metric
        self.potentialSavings = potentialSavings
    }
}

/// Rule-based analysis of where tokens go and what would reduce them.
///
/// All dollar figures are API-equivalent list prices. On a Pro/Max plan they
/// are not charged, but they track how fast usage limits are consumed.
public struct InsightEngine {
    public var pricing: PricingTable

    /// Prompt size above which a request counts as "large context".
    public var largeContextThreshold = 150_000
    /// Minimum context for a request to count as a cache re-warm.
    public var rewarmMinimumContext = 20_000
    /// What-if target for top-tier traffic.
    public var cheaperModelPrefix = "claude-sonnet-5-5"

    public init(pricing: PricingTable) {
        self.pricing = pricing
    }

    public func analyze(_ events: [PricedEvent]) -> [Insight] {
        let summary = UsageSummary.of(events)
        guard summary.requests > 0, summary.cost.total > 0 else { return [] }

        var insights: [Insight] = []
        insights += cacheEfficiency(summary)
        insights += cacheWrites(summary)
        insights += cacheRewarms(events, summary: summary)
        insights += largeContext(events, summary: summary)
        insights += modelMix(events, summary: summary)
        insights += effort(events, summary: summary)
        insights += subagents(events, summary: summary)
        insights += concentration(events, summary: summary)
        insights += fastMode(events, summary: summary)
        insights += estimatedPrices(events)

        return insights.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return ($0.potentialSavings ?? 0) > ($1.potentialSavings ?? 0)
        }
    }

    // MARK: Rules

    private func cacheEfficiency(_ summary: UsageSummary) -> [Insight] {
        let hit = summary.tokens.cacheHitRate
        let metric = Fmt.percent(hit)
        if hit >= 0.85 {
            return [Insight(
                id: "cache.hit", severity: .good, kind: .observation,
                title: "Кэш промптов работает хорошо",
                detail: "\(metric) контекста читается из кэша — это самый дешёвый вид входных токенов.",
                metric: metric
            )]
        }
        let severity: InsightSeverity = hit < 0.6 ? .warning : .info
        return [Insight(
            id: "cache.hit", severity: severity, kind: .freeWin,
            title: "Низкая доля попаданий в кэш",
            detail: "Из кэша читается только \(metric) контекста. Остальное оплачивается как свежий ввод или как запись в кэш, которая дороже ввода.",
            recommendation: "Не меняйте модель и настройки посреди сессии, держите CLAUDE.md и системные инструкции стабильными, между задачами начинайте новую сессию (/clear), а не продолжайте старую с другим контекстом.",
            metric: metric
        )]
    }

    private func cacheWrites(_ summary: UsageSummary) -> [Insight] {
        let share = summary.cost.cacheWrite / summary.cost.total
        guard share >= 0.25 else { return [] }
        let writes = summary.tokens.cacheWrite
        let oneHourShare = writes > 0 ? Double(summary.tokens.cacheWrite1h) / Double(writes) : 0
        var detail = "Запись в кэш — \(Fmt.percent(share)) стоимости (\(Fmt.usd(summary.cost.cacheWrite)))."
        if oneHourShare > 0.5 {
            detail += " \(Fmt.percent(oneHourShare)) записей идут с TTL 1 час: такая запись стоит 2× цены ввода (TTL 5 минут — 1.25×), зато переживает паузы до часа."
        }
        return [Insight(
            id: "cache.writes", severity: share >= 0.4 ? .warning : .info, kind: .freeWin,
            title: "Много платите за запись в кэш",
            detail: detail,
            recommendation: "Каждый раз, когда начало контекста меняется, весь контекст после изменения записывается в кэш заново. Сокращайте контекст (/compact), не переключайте модель внутри длинной сессии и начинайте новую задачу с /clear.",
            metric: Fmt.percent(share)
        )]
    }

    /// Requests after an idle gap longer than the cache TTL that rewrote most of their context.
    private func cacheRewarms(_ events: [PricedEvent], summary: UsageSummary) -> [Insight] {
        var count = 0
        var cost = 0.0
        var avoidable = 0.0
        var previousBySession: [String: PricedEvent] = [:]
        var priceCache: [String: ModelPrice?] = [:]

        for priced in events.sorted(by: { $0.event.timestamp < $1.event.timestamp }) {
            let event = priced.event
            defer { previousBySession[event.sessionID] = priced }
            guard let previous = previousBySession[event.sessionID] else { continue }

            let ttl: TimeInterval = previous.event.tokens.cacheWrite1h > 0 ? 3600 : 300
            let gap = event.timestamp.timeIntervalSince(previous.event.timestamp)
            let t = event.tokens
            guard gap > ttl, t.contextTokens >= rewarmMinimumContext, Double(t.cacheWrite) >= 0.5 * Double(t.contextTokens) else {
                continue
            }
            count += 1
            cost += priced.cost.cacheWrite

            let price: ModelPrice?
            if let cached = priceCache[event.model] {
                price = cached
            } else {
                price = pricing.match(model: event.model).price
                priceCache[event.model] = price
            }
            if let price {
                // Had the cache still been warm, these tokens would have been reads.
                let writeCost = (Double(t.cacheWrite5m) * price.cacheWrite5m + Double(t.cacheWrite1h) * price.cacheWrite1h) / 1_000_000
                let readCost = Double(t.cacheWrite) * price.cacheRead / 1_000_000
                avoidable += max(0, writeCost - readCost)
            }
        }

        guard count >= 3, cost / summary.cost.total >= 0.03 else { return [] }
        return [Insight(
            id: "cache.rewarm", severity: cost / summary.cost.total >= 0.1 ? .warning : .info, kind: .freeWin,
            title: "Паузы обнуляют кэш",
            detail: "\(count) раз после паузы длиннее срока жизни кэша весь контекст сессии записывался заново: \(Fmt.usd(cost)) за запись.",
            recommendation: "Возвращаясь после перерыва к новой задаче, начинайте её с /clear. Если нужен прежний контекст, сделайте /compact перед перерывом, чтобы перезаписывать меньше.",
            metric: "\(count)×",
            potentialSavings: avoidable
        )]
    }

    private func largeContext(_ events: [PricedEvent], summary: UsageSummary) -> [Insight] {
        let large = events.filter { $0.event.tokens.contextTokens > largeContextThreshold }
        guard !large.isEmpty else { return [] }
        let largeCost = large.reduce(0) { $0 + $1.cost.total }
        let share = largeCost / summary.cost.total
        guard share >= 0.2 else { return [] }
        return [Insight(
            id: "context.large", severity: share >= 0.5 ? .warning : .info, kind: .freeWin,
            title: "Дорогой длинный контекст",
            detail: "\(Fmt.percent(share)) стоимости (\(Fmt.usd(largeCost))) приходится на запросы с контекстом больше \(Fmt.tokens(largeContextThreshold)) токенов. Средний контекст запроса — \(Fmt.tokens(Int(summary.averageContextTokens))).",
            recommendation: "Каждый ход заново отправляет весь контекст сессии. Делайте /compact на длинных задачах, /clear между независимыми задачами, не читайте большие файлы и логи целиком и держите CLAUDE.md коротким.",
            metric: Fmt.percent(share)
        )]
    }

    private func modelMix(_ events: [PricedEvent], summary: UsageSummary) -> [Insight] {
        let topTier = events.filter { ModelCatalog.family(of: $0.event.model).isTopTier }
        guard !topTier.isEmpty else { return [] }
        let topCost = topTier.reduce(0) { $0 + $1.cost.total }
        let share = topCost / summary.cost.total
        guard share >= 0.7, let whatIf = pricing.cost(of: topTier, asModel: cheaperModelPrefix), whatIf < topCost else {
            return []
        }
        let savings = topCost - whatIf
        let cheaperName = pricing.models.first { $0.modelPrefix == cheaperModelPrefix }?.displayName ?? cheaperModelPrefix
        return [Insight(
            id: "model.mix", severity: .info, kind: .tradeoff,
            title: "Почти всё уходит на старшие модели",
            detail: "\(Fmt.percent(share)) стоимости — Opus/Fable. Те же запросы на \(cheaperName) стоили бы \(Fmt.usd(whatIf)) вместо \(Fmt.usd(topCost)).",
            recommendation: "Для рутинных задач (правки, тесты, поиск по коду) переключайтесь на \(cheaperName) командой /model. На подписке это обычно медленнее расходует лимит окна. Качество на сложных задачах может отличаться — проверьте на своих.",
            metric: Fmt.percent(share),
            potentialSavings: savings
        )]
    }

    private func effort(_ events: [PricedEvent], summary: UsageSummary) -> [Insight] {
        let high = events.filter { ["xhigh", "max"].contains($0.event.effort?.lowercased() ?? "") }
        let thinkingShare = summary.tokens.output > 0 ? Double(summary.tokens.thinking) / Double(summary.tokens.output) : 0
        let requestShare = Double(high.count) / Double(summary.requests)
        guard requestShare >= 0.5, thinkingShare >= 0.3 else { return [] }
        return [Insight(
            id: "effort.high", severity: .info, kind: .tradeoff,
            title: "Высокий effort по умолчанию",
            detail: "\(Fmt.percent(requestShare)) запросов идут с effort xhigh/max; размышления — \(Fmt.percent(thinkingShare)) выходных токенов.",
            recommendation: "Высокий effort окупается на сложных задачах. Для простых правок и вопросов понизьте effort в настройках модели Claude Code — это сокращает размышления и число вызовов инструментов.",
            metric: Fmt.percent(requestShare)
        )]
    }

    private func subagents(_ events: [PricedEvent], summary: UsageSummary) -> [Insight] {
        let sidechain = events.filter { $0.event.isSidechain }.reduce(0) { $0 + $1.cost.total }
        let share = sidechain / summary.cost.total
        guard share >= 0.3 else { return [] }
        return [Insight(
            id: "subagents", severity: .info, kind: .observation,
            title: "Субагенты — заметная часть расходов",
            detail: "\(Fmt.percent(share)) стоимости (\(Fmt.usd(sidechain))) тратят субагенты. Каждый начинает со своего контекста и не делит кэш с основной сессией.",
            recommendation: "Субагенты выгодны для объёмного чтения и поиска. Для мелких шагов, которым нужен контекст основной сессии, они обходятся дороже.",
            metric: Fmt.percent(share)
        )]
    }

    private func concentration(_ events: [PricedEvent], summary: UsageSummary) -> [Insight] {
        let sessions = SessionAnalytics.sessions(events)
        guard sessions.count >= 3, let top = sessions.first else { return [] }
        let share = top.cost / summary.cost.total
        guard share >= 0.3 else { return [] }
        return [Insight(
            id: "sessions.concentration", severity: .info, kind: .observation,
            title: "Одна сессия съела большую часть",
            detail: "Сессия в «\(top.projectName)» от \(Fmt.dateTime(top.start)) — \(Fmt.percent(share)) стоимости периода (\(Fmt.usd(top.cost)), \(top.requests) запросов, пик контекста \(Fmt.tokens(top.peakContextTokens))).",
            recommendation: "Длинные сессии дорожают с каждым ходом: весь накопленный контекст отправляется снова. Дробите большие задачи на сессии поменьше.",
            metric: Fmt.percent(share)
        )]
    }

    private func fastMode(_ events: [PricedEvent], summary: UsageSummary) -> [Insight] {
        let fast = events.filter { $0.event.isFastMode }
        guard !fast.isEmpty, pricing.fastModeMultiplier > 1 else { return [] }
        let fastCost = fast.reduce(0) { $0 + $1.cost.total }
        let premium = fastCost * (1 - 1 / pricing.fastModeMultiplier)
        return [Insight(
            id: "fast.mode", severity: .info, kind: .tradeoff,
            title: "Fast mode",
            detail: "\(fast.count) запросов шли в fast mode: \(Fmt.usd(fastCost)), из них наценка за скорость — \(Fmt.usd(premium)).",
            recommendation: "Включайте fast mode, когда важна скорость ответа, и выключайте для фоновых задач.",
            metric: "\(fast.count)",
            potentialSavings: premium
        )]
    }

    private func estimatedPrices(_ events: [PricedEvent]) -> [Insight] {
        let models = Set(events.filter(\.isEstimated).map(\.event.model))
        guard !models.isEmpty else { return [] }
        let list = models.sorted().joined(separator: ", ")
        return [Insight(
            id: "pricing.estimated", severity: .info, kind: .observation,
            title: "Цены для части моделей оценены",
            detail: "Для \(list) нет точной строки в таблице цен; стоимость взята по семейству модели.",
            recommendation: "Добавьте эти модели в «Настройки → Цены».",
            metric: "\(models.count)"
        )]
    }
}
