import Foundation

public enum InsightSeverity: Int, Comparable, Sendable, CaseIterable {
    case good = 0, info = 1, warning = 2, critical = 3

    public static func < (lhs: InsightSeverity, rhs: InsightSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .good: return L("Хорошо")
        case .info: return L("Совет")
        case .warning: return L("Внимание")
        case .critical: return L("Критично")
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
        case .freeWin: return L("Без потери качества")
        case .tradeoff: return L("Компромисс")
        case .observation: return L("Наблюдение")
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
        insights += requestIssues(events, summary: summary)
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
                title: L("Кэш промптов работает хорошо"),
                detail: L("\(metric) контекста читается из кэша — это самый дешёвый вид входных токенов."),
                metric: metric
            )]
        }
        let severity: InsightSeverity = hit < 0.6 ? .warning : .info
        return [Insight(
            id: "cache.hit", severity: severity, kind: .freeWin,
            title: L("Низкая доля попаданий в кэш"),
            detail: L("Из кэша читается только \(metric) контекста. Остальное оплачивается как свежий ввод или как запись в кэш, которая дороже ввода."),
            recommendation: L("Не меняйте модель и настройки посреди сессии, держите CLAUDE.md и системные инструкции стабильными, между задачами начинайте новую сессию (/clear), а не продолжайте старую с другим контекстом."),
            metric: metric
        )]
    }

    private func cacheWrites(_ summary: UsageSummary) -> [Insight] {
        let share = summary.cost.cacheWrite / summary.cost.total
        guard share >= 0.25 else { return [] }
        let writes = summary.tokens.cacheWrite
        let oneHourShare = writes > 0 ? Double(summary.tokens.cacheWrite1h) / Double(writes) : 0
        var detail = L("Запись в кэш — \(Fmt.percent(share)) стоимости (\(Fmt.usd(summary.cost.cacheWrite))).")
        if oneHourShare > 0.5 {
            detail += L(" \(Fmt.percent(oneHourShare)) записей идут с TTL 1 час: такая запись стоит 2× цены ввода (TTL 5 минут — 1.25×), зато переживает паузы до часа.")
        }
        return [Insight(
            id: "cache.writes", severity: share >= 0.4 ? .warning : .info, kind: .freeWin,
            title: L("Много платите за запись в кэш"),
            detail: detail,
            recommendation: L("Каждый раз, когда начало контекста меняется, весь контекст после изменения записывается в кэш заново. Сокращайте контекст (/compact), не переключайте модель внутри длинной сессии и начинайте новую задачу с /clear."),
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
            title: L("Паузы обнуляют кэш"),
            detail: L("\(count) раз после паузы длиннее срока жизни кэша весь контекст сессии записывался заново: \(Fmt.usd(cost)) за запись."),
            recommendation: L("Возвращаясь после перерыва к новой задаче, начинайте её с /clear. Если нужен прежний контекст, сделайте /compact перед перерывом, чтобы перезаписывать меньше."),
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
            title: L("Дорогой длинный контекст"),
            detail: L("\(Fmt.percent(share)) стоимости (\(Fmt.usd(largeCost))) приходится на запросы с контекстом больше \(Fmt.tokens(largeContextThreshold)) токенов. Средний контекст запроса — \(Fmt.tokens(Int(summary.averageContextTokens)))."),
            recommendation: L("Каждый ход заново отправляет весь контекст сессии. Делайте /compact на длинных задачах, /clear между независимыми задачами, не читайте большие файлы и логи целиком и держите CLAUDE.md коротким."),
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
            title: L("Почти всё уходит на старшие модели"),
            detail: L("\(Fmt.percent(share)) стоимости — Opus/Fable. Те же запросы на \(cheaperName) стоили бы \(Fmt.usd(whatIf)) вместо \(Fmt.usd(topCost))."),
            recommendation: L("Для рутинных задач (правки, тесты, поиск по коду) переключайтесь на \(cheaperName) командой /model. На подписке это обычно медленнее расходует лимит окна. Качество на сложных задачах может отличаться — проверьте на своих."),
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
            title: L("Высокий effort по умолчанию"),
            detail: L("\(Fmt.percent(requestShare)) запросов идут с effort xhigh/max; размышления — \(Fmt.percent(thinkingShare)) выходных токенов."),
            recommendation: L("Высокий effort окупается на сложных задачах. Для простых правок и вопросов понизьте effort в настройках модели Claude Code — это сокращает размышления и число вызовов инструментов."),
            metric: Fmt.percent(requestShare)
        )]
    }

    private func subagents(_ events: [PricedEvent], summary: UsageSummary) -> [Insight] {
        let sidechain = events.filter { $0.event.isSidechain }.reduce(0) { $0 + $1.cost.total }
        let share = sidechain / summary.cost.total
        guard share >= 0.3 else { return [] }
        return [Insight(
            id: "subagents", severity: .info, kind: .observation,
            title: L("Субагенты — заметная часть расходов"),
            detail: L("\(Fmt.percent(share)) стоимости (\(Fmt.usd(sidechain))) тратят субагенты. Каждый начинает со своего контекста и не делит кэш с основной сессией."),
            recommendation: L("Субагенты выгодны для объёмного чтения и поиска. Для мелких шагов, которым нужен контекст основной сессии, они обходятся дороже."),
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
            title: L("Одна сессия съела большую часть"),
            detail: L("Сессия в «\(top.projectName)» от \(Fmt.dateTime(top.start)) — \(Fmt.percent(share)) стоимости периода (\(Fmt.usd(top.cost)), \(top.requests) запросов, пик контекста \(Fmt.tokens(top.peakContextTokens)))."),
            recommendation: L("Длинные сессии дорожают с каждым ходом: весь накопленный контекст отправляется снова. Дробите большие задачи на сессии поменьше."),
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
            detail: L("\(fast.count) запросов шли в fast mode: \(Fmt.usd(fastCost)), из них наценка за скорость — \(Fmt.usd(premium))."),
            recommendation: L("Включайте fast mode, когда важна скорость ответа, и выключайте для фоновых задач."),
            metric: "\(fast.count)",
            potentialSavings: premium
        )]
    }

    /// Cache misses with a cause, reasoning the API dropped, refusals, cut-off answers, fallbacks.
    private func requestIssues(_ events: [PricedEvent], summary: UsageSummary) -> [Insight] {
        let issues = RequestIssues.of(events, pricing: pricing)
        let total = summary.cost.total
        var insights: [Insight] = []

        if issues.realMisses > 0 {
            let real = issues.misses.filter { LLMCalls.isRealMiss($0.reason) }
            let parts = real.map { L("\(LLMCalls.cacheMissTitle($0.reason)) — \(Fmt.plural($0.count, "раз", "раза", "раз")), \(Fmt.tokens($0.missedTokens)) токенов") }
            let share = total > 0 ? issues.realExtraCost / total : 0
            insights.append(Insight(
                id: "cache.misses",
                severity: share >= 0.05 || issues.realMisses >= 10 ? .warning : .info,
                kind: .freeWin,
                title: L("Кэш сбрасывался из-за изменений в запросе"),
                detail: L("API сообщило о \(Fmt.plural(issues.realMisses, "промахе", "промахах", "промахах")) кэша с понятной причиной: \(parts.joined(separator: "; ")). Эти токены записаны в кэш заново вместо дешёвого чтения: ≈\(Fmt.usd(issues.realExtraCost))."),
                recommendation: real.first.map { LLMCalls.cacheMissAdvice($0.reason) },
                metric: "\(issues.realMisses)",
                potentialSavings: issues.realExtraCost > 0 ? issues.realExtraCost : nil
            ))
        }

        if issues.droppedRequests > 0 {
            let reasons = issues.dropped.map { "\(LLMCalls.droppedReasonTitle($0.reason)) — \(Fmt.plural($0.blocks, "блок", "блока", "блоков"))" }
            insights.append(Insight(
                id: "thinking.dropped",
                severity: issues.droppedRequests >= 10 ? .warning : .info,
                kind: .freeWin,
                title: L("Модель теряла свои прежние размышления"),
                detail: L("В \(Fmt.plural(issues.droppedRequests, "запросе", "запросах", "запросах")) API убрало из истории размышления модели: \(reasons.joined(separator: "; ")). Модель не видела, как рассуждала раньше, и восстанавливала это заново — лишний вывод и время."),
                recommendation: L("Не меняйте модель и историю посреди задачи: откат, правка сообщений, смена модели или настройки инструментов делают прежние размышления недействительными."),
                metric: "\(issues.droppedRequests)"
            ))
        }

        if issues.truncated > 0 {
            insights.append(Insight(
                id: "stop.max_tokens", severity: .warning, kind: .observation,
                title: L("Ответы обрывались на лимите вывода"),
                detail: L("\(Fmt.plural(issues.truncated, "ответ", "ответа", "ответов")) остановились по max_tokens: модель не успела закончить, и Claude Code продолжал или повторял запрос."),
                recommendation: L("Увеличьте лимит вывода (переменная CLAUDE_CODE_MAX_OUTPUT_TOKENS) или просите модель делать изменения меньшими частями."),
                metric: "\(issues.truncated)"
            ))
        }

        if !issues.refusals.isEmpty {
            let count = issues.refusals.values.reduce(0, +)
            let categories = issues.refusals.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            let fallback = issues.fallbacks > 0 ? L(" \(Fmt.plural(issues.fallbacks, "ответ", "ответа", "ответов")) дала резервная модель.") : ""
            insights.append(Insight(
                id: "stop.refusal", severity: .info, kind: .observation,
                title: L("Модель отказывала в ответе"),
                detail: L("\(Fmt.plural(count, "отказ", "отказа", "отказов")) по категориям защитных классификаторов (\(categories)).\(fallback)"),
                metric: "\(count)"
            ))
        } else if issues.fallbacks > 0 {
            insights.append(Insight(
                id: "stop.fallback", severity: .info, kind: .observation,
                title: L("Отвечала резервная модель"),
                detail: L("\(Fmt.plural(issues.fallbacks, "ответ", "ответа", "ответов")) дала резервная модель после отказа основной."),
                metric: "\(issues.fallbacks)"
            ))
        }

        if issues.modelSwitches > 0 {
            insights.append(Insight(
                id: "model.switched", severity: .info, kind: .observation,
                title: L("Запросы обслуживала другая модель"),
                detail: L("В \(Fmt.plural(issues.modelSwitches, "запросе", "запросах", "запросах")) ответила не та модель, которую запросил Claude Code (резервная модель или переключение). Кэш и размышления у разных моделей не общие."),
                metric: "\(issues.modelSwitches)"
            ))
        }
        return insights
    }

    private func estimatedPrices(_ events: [PricedEvent]) -> [Insight] {
        let models = Set(events.filter(\.isEstimated).map(\.event.model))
        guard !models.isEmpty else { return [] }
        let list = models.sorted().joined(separator: ", ")
        return [Insight(
            id: "pricing.estimated", severity: .info, kind: .observation,
            title: L("Цены для части моделей оценены"),
            detail: L("Для \(list) нет точной строки в таблице цен; стоимость взята по семейству модели."),
            recommendation: L("Добавьте эти модели в «Настройки → Цены»."),
            metric: "\(models.count)"
        )]
    }
}
