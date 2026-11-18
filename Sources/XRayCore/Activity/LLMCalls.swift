import Foundation

/// One request to the model: the response's blocks, the actions it took, usage and API details.
public struct LLMCall: Identifiable, Sendable {
    /// 1-based position in the session, in time order.
    public let index: Int
    public let step: ModelStep
    public let priced: PricedEvent?
    /// Turn the request belongs to (the index of `SessionTrace.turns`).
    public let turn: Int
    public let thinking: [ActivityItem]
    public let replies: [ActivityItem]
    /// Tool calls the response made (its actions), with their results.
    public let tools: [ToolExecution]

    public var id: String { step.messageID + "#\(index)" }
    public var details: RequestDetails { priced?.event.details ?? RequestDetails() }
    public var contextTokens: Int { priced?.event.tokens.contextTokens ?? 0 }
    public var cost: Double { priced?.cost.total ?? 0 }

    /// The model ran on a different model than Claude Code asked for.
    public var modelSwitched: Bool {
        guard let requested = step.requestedModel ?? details.requestedModel,
              let served = step.model ?? priced?.event.model else { return false }
        return PricingTable.normalize(requested) != PricingTable.normalize(served)
    }

    /// A cache miss with a known cause, lost reasoning, a refusal, a cut-off or a failed tool.
    public var hasIssue: Bool {
        let d = details
        return (d.cacheMiss.map { LLMCalls.isRealMiss($0.reason) } ?? false)
            || d.droppedThinking > 0
            || d.stopReason == "refusal"
            || d.stopReason == "max_tokens"
            || modelSwitched
            || tools.contains { $0.isError }
    }
}

public enum LLMCalls {
    public static func build(trace: SessionTrace, usage: [String: PricedEvent]) -> [LLMCall] {
        let toolByCall = Dictionary(trace.tools.map { ($0.call.id, $0) }, uniquingKeysWith: { first, _ in first })
        var turnOf: [String: Int] = [:]
        for (position, turn) in trace.turns.enumerated() {
            for id in turn.stepIDs where turnOf[id] == nil { turnOf[id] = position }
        }
        var itemsByMessage: [String: [ActivityItem]] = [:]
        for item in trace.items {
            guard let messageID = item.messageID else { continue }
            itemsByMessage[messageID, default: []].append(item)
        }
        return trace.steps.enumerated().map { position, step in
            let items = itemsByMessage[step.messageID] ?? []
            return LLMCall(
                index: position + 1,
                step: step,
                priced: usage[step.messageID],
                turn: turnOf[step.messageID] ?? 0,
                thinking: items.filter { $0.kind == .thinking },
                replies: items.filter { $0.kind == .reply },
                tools: step.toolCallIDs.compactMap { toolByCall[$0] }
            )
        }
    }

    // MARK: Labels

    public enum Tone: Sendable { case good, info, warning, critical, neutral }

    /// Meaning of a stop reason and how alarming it is.
    public static func stopReason(_ reason: String?, category: String? = nil) -> (title: String, tone: Tone) {
        switch reason {
        case "end_turn"?: return ("ответ готов", .good)
        case "tool_use"?: return ("вызов инструментов", .info)
        case "max_tokens"?: return ("обрезан лимитом вывода", .warning)
        case "stop_sequence"?: return ("стоп-последовательность", .neutral)
        case "pause_turn"?: return ("пауза серверного инструмента", .neutral)
        case "refusal"?: return (category.map { "отказ: \($0)" } ?? "отказ", .critical)
        case "model_context_window_exceeded"?: return ("окно контекста переполнено", .critical)
        case nil, ""?: return ("—", .neutral)
        case let other?: return (other, .neutral)
        }
    }

    /// Cache misses with a cause in the request itself, not just a missing comparison point.
    public static func isRealMiss(_ reason: String) -> Bool {
        reason != "previous_message_not_found" && reason != "unavailable"
    }

    public static func cacheMissTitle(_ reason: String) -> String {
        switch reason {
        case "system_changed": return "изменился системный промпт"
        case "tools_changed": return "изменились инструменты (набор или описания)"
        case "messages_changed": return "изменилась история сообщений"
        case "model_changed": return "сменилась модель"
        case "multiple": return "изменилось несколько частей запроса"
        case "unrelated": return "запрос из другого разговора"
        case "previous_message_not_found": return "не с чем сравнить: первый запрос, пауза дольше TTL или другой поток"
        case "unavailable": return "диагностика недоступна"
        default: return reason
        }
    }

    public static func cacheMissAdvice(_ reason: String) -> String {
        switch reason {
        case "system_changed": return "Системный промпт менялся посреди сессии: правки CLAUDE.md или памяти, смена режима, настроек или версии Claude Code. Вносите такие изменения между сессиями."
        case "tools_changed": return "Набор инструментов менялся по ходу: MCP-серверы подключались или отключались, менялись разрешения или описания инструментов. Подключайте нужные MCP до начала работы."
        case "messages_changed": return "История сообщений менялась: откат (/rewind), правка или удаление сообщений, хуки, переписывающие ввод."
        case "model_changed": return "Модель менялась посреди сессии (/model или резервная модель): у каждой модели свой кэш."
        default: return "Держите системный промпт, инструменты и модель неизменными в течение сессии."
        }
    }

    public static func droppedReasonTitle(_ reason: String?) -> String {
        switch reason {
        case "prefix_binding_mismatch"?: return "история изменилась после размышления"
        case "model_binding_mismatch"?: return "модель не читает размышления прежней модели"
        case "organization_binding_mismatch"?: return "размышление из другого аккаунта"
        case nil: return "причина не указана"
        case let other?: return other
        }
    }

    public static func iterationTitle(_ type: String) -> String {
        switch type {
        case "message": return "ответ модели"
        case "fallback_message": return "ответ резервной модели"
        case "compaction": return "сжатие контекста на сервере"
        case "advisor_message": return "совет модели-советника"
        default: return type
        }
    }

    public static func thinkingDisplayTitle(_ display: String?) -> String {
        switch display {
        case "summarized"?: return "краткое изложение"
        case "updates"?: return "заметки по ходу работы"
        case "omitted"?: return "текст не возвращается"
        case "redacted"?: return "зашифровано"
        case nil: return "—"
        case let other?: return other
        }
    }

    public static func decisionTitle(_ item: ActivityItem) -> String? {
        guard item.decision != nil || item.decidedBy != nil else { return item.permission }
        let verdict: String
        switch item.decision {
        case "accept"?: verdict = "разрешено"
        case "reject"?, "deny"?: verdict = "запрещено"
        case let other?: verdict = other
        case nil: verdict = "решение"
        }
        let by: String?
        switch item.decidedBy {
        case "classifier"?: by = "классификатор auto mode"
        case "rule"?: by = "правило"
        case "user"?, "userApproval"?: by = "вы"
        case "hook"?: by = "хук"
        case "mode"?: by = "режим"
        case "config"?: by = "настройки"
        default: by = item.decidedBy
        }
        let rule = item.ruleSource.map { " (\($0))" } ?? ""
        return by.map { "\(verdict): \($0)\(rule)" } ?? verdict
    }
}

// MARK: - Request-level analytics

public struct CacheMissGroup: Identifiable, Hashable, Sendable {
    public let reason: String
    public var count: Int
    /// Prompt tokens the API reports as missed; for causes without a count, tokens written to the cache.
    public var missedTokens: Int
    /// Extra cost of writing those tokens instead of reading them from the cache (API-equivalent USD).
    public var extraCost: Double
    /// The API reported the missed tokens (as opposed to the written-tokens estimate).
    public var exact: Bool

    public var id: String { reason }
}

public struct DroppedGroup: Identifiable, Hashable, Sendable {
    public let reason: String
    public var requests: Int
    public var blocks: Int

    public var id: String { reason }
}

/// Cache misses, dropped reasoning, refusals, cut-off answers and fallbacks over a set of requests.
public struct RequestIssues: Sendable {
    public var requests = 0
    public var misses: [CacheMissGroup] = []
    /// Totals over misses with a cause in the request (not "nothing to compare with").
    public var realMisses = 0
    public var realMissedTokens = 0
    public var realExtraCost = 0.0
    public var dropped: [DroppedGroup] = []
    public var droppedRequests = 0
    public var refusals: [String: Int] = [:]
    public var truncated = 0
    public var fallbacks = 0
    public var modelSwitches = 0
    public var contextEdits = 0
    public var stopReasons: [String: Int] = [:]

    public init() {}

    /// Cost of writing `tokens` to the cache instead of reading them, at the request's model and TTL.
    public static func missExtraCost(pricing: PricingTable, priced: PricedEvent, tokens: Int) -> Double {
        guard tokens > 0, let price = pricing.match(model: priced.event.model).price else { return 0 }
        let writeRate = priced.event.tokens.cacheWrite1h > 0 ? price.cacheWrite1h : price.cacheWrite5m
        let multiplier = priced.event.isFastMode ? pricing.fastModeMultiplier : 1
        return max(0, (writeRate - price.cacheRead) * Double(tokens) * multiplier / 1_000_000)
    }

    public static func of(_ events: [PricedEvent], pricing: PricingTable) -> RequestIssues {
        var issues = RequestIssues()
        issues.requests = events.count
        var misses: [String: CacheMissGroup] = [:]
        var dropped: [String: DroppedGroup] = [:]
        for priced in events {
            guard let d = priced.event.details else { continue }
            if let stop = d.stopReason { issues.stopReasons[stop, default: 0] += 1 }
            if d.stopReason == "refusal" { issues.refusals[d.stopCategory ?? "—", default: 0] += 1 }
            if d.stopReason == "max_tokens" { issues.truncated += 1 }
            if d.iterations.contains(where: { $0.type == "fallback_message" }) { issues.fallbacks += 1 }
            if let requested = d.requestedModel, PricingTable.normalize(requested) != PricingTable.normalize(priced.event.model) {
                issues.modelSwitches += 1
            }
            if !d.contextEdits.isEmpty { issues.contextEdits += 1 }
            if let miss = d.cacheMiss {
                let tokens = miss.missedTokens ?? priced.event.tokens.cacheWrite
                let real = LLMCalls.isRealMiss(miss.reason)
                let extra = real ? missExtraCost(pricing: pricing, priced: priced, tokens: tokens) : 0
                var group = misses[miss.reason] ?? CacheMissGroup(reason: miss.reason, count: 0, missedTokens: 0, extraCost: 0, exact: true)
                group.count += 1
                group.missedTokens += tokens
                group.extraCost += extra
                group.exact = group.exact && miss.missedTokens != nil
                misses[miss.reason] = group
                if real {
                    issues.realMisses += 1
                    issues.realMissedTokens += tokens
                    issues.realExtraCost += extra
                }
            }
            let drops = d.transformations.filter { $0.type == "thinking_dropped" }
            if !drops.isEmpty {
                issues.droppedRequests += 1
                for drop in drops {
                    let reason = drop.reason ?? "unknown"
                    var group = dropped[reason] ?? DroppedGroup(reason: reason, requests: 0, blocks: 0)
                    group.blocks += 1
                    dropped[reason] = group
                }
                for reason in Set(drops.map { $0.reason ?? "unknown" }) {
                    dropped[reason]?.requests += 1
                }
            }
        }
        issues.misses = misses.values.sorted {
            $0.extraCost != $1.extraCost ? $0.extraCost > $1.extraCost : $0.count > $1.count
        }
        issues.dropped = dropped.values.sorted { $0.blocks > $1.blocks }
        return issues
    }
}
