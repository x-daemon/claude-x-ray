import SwiftUI
import XRayCore

/// Request-level health for a period: why the cache missed and what it cost, how answers ended,
/// reasoning the API dropped, fallbacks. Shown on "Оптимизация" and in the report.
struct RequestHealthCard: View {
    @Environment(AppModel.self) private var model
    let events: [PricedEvent]

    /// Nothing to show for periods whose transcripts predate these fields.
    static func hasDetails(_ events: [PricedEvent]) -> Bool {
        events.contains { $0.event.details?.stopReason != nil || $0.event.details?.cacheMiss != nil }
    }

    var body: some View {
        if Self.hasDetails(events) {
            let issues = RequestIssues.of(events, pricing: model.pricing)
            Card(title: L("Запросы к модели"), subtitle: subtitle(issues)) {
                CardRow(minWidth: 280) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Почему не срабатывал кэш")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if issues.misses.isEmpty {
                            Text(L("Промахов кэша API не сообщало.")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            RankedBarList(rows: missRows(issues), labelWidth: 250)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Чем заканчивались ответы")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        RankedBarList(rows: stopRows(issues), labelWidth: 180)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                let facts = self.facts(issues)
                if !facts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: fact.icon).foregroundStyle(fact.color).frame(width: 16)
                                Text(fact.text).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                }
                Text(L("Причины промахов кэша и потерянные размышления сообщает сам API (диагностика кэша, input_transformations); «не с чем сравнить» — первый запрос, пауза дольше TTL кэша или другой поток. Подробности по каждому запросу — в Live-трассе, вкладка «LLM-запросы»."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func subtitle(_ issues: RequestIssues) -> String {
        issues.realMisses > 0
            ? L("промахов кэша с причиной: \(issues.realMisses) · лишняя запись ≈\(Fmt.usd(issues.realExtraCost))")
            : L("по данным API в логах Claude Code")
    }

    private func missRows(_ issues: RequestIssues) -> [RankedBarRow] {
        issues.misses.map { group in
            let real = LLMCalls.isRealMiss(group.reason)
            let written = group.exact ? "" : L(" записано")
            return RankedBarRow(
                id: group.reason,
                label: LLMCalls.cacheMissTitle(group.reason),
                detail: L("\(Fmt.plural(group.count, "запрос", "запроса", "запросов")) · \(Fmt.tokens(group.missedTokens)) токенов\(written)"),
                value: real ? max(group.extraCost, 0.0001) : 0.0001,
                valueText: real ? "≈\(Fmt.usd(group.extraCost))" : "—",
                color: real ? Palette.warning : Palette.other
            )
        }
    }

    private func stopRows(_ issues: RequestIssues) -> [RankedBarRow] {
        issues.stopReasons.sorted { $0.value > $1.value }.map { reason, count in
            let info = LLMCalls.stopReason(reason)
            let color: Color
            switch info.tone {
            case .good: color = Palette.model
            case .info: color = Palette.tool
            default: color = info.tone.color
            }
            return RankedBarRow(
                id: reason,
                label: info.title,
                detail: reason,
                value: Double(count),
                valueText: "\(count) · \(Fmt.percent(Double(count) / Double(max(issues.requests, 1))))",
                color: color
            )
        }
    }

    private func facts(_ issues: RequestIssues) -> [(icon: String, color: Color, text: String)] {
        var facts: [(icon: String, color: Color, text: String)] = []
        if issues.droppedRequests > 0 {
            let reasons = issues.dropped.map { "\(LLMCalls.droppedReasonTitle($0.reason)) (\($0.blocks))" }.joined(separator: ", ")
            facts.append(("brain", Palette.warning, L("API убирало размышления из истории в \(Fmt.plural(issues.droppedRequests, "запросе", "запросах", "запросах")): \(reasons)")))
        }
        if issues.truncated > 0 {
            facts.append(("exclamationmark.triangle.fill", Palette.warning, L("Обрезано лимитом вывода: \(Fmt.plural(issues.truncated, "ответ", "ответа", "ответов"))")))
        }
        if !issues.refusals.isEmpty {
            let list = issues.refusals.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            facts.append(("xmark.octagon.fill", Palette.critical, L("Отказы: \(list)")))
        }
        if issues.fallbacks > 0 {
            facts.append(("square.stack.3d.up", Palette.other, L("Ответов резервной модели: \(issues.fallbacks)")))
        }
        if issues.modelSwitches > 0 {
            facts.append(("arrow.triangle.swap", Palette.other, L("Ответила не та модель, что запрошена: \(Fmt.plural(issues.modelSwitches, "раз", "раза", "раз"))")))
        }
        if issues.contextEdits > 0 {
            facts.append(("arrow.down.right.and.arrow.up.left", Palette.context, L("Сервер очищал контекст в \(Fmt.plural(issues.contextEdits, "запросе", "запросах", "запросах"))")))
        }
        return facts
    }
}
