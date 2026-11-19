import SwiftUI
import XRayCore

/// Optimisation findings for the selected period.
struct InsightsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let events = model.periodEvents
        let insights = InsightEngine(pricing: model.pricing).analyze(events)
        let summary = UsageSummary.of(events)
        let freeSavings = insights.filter { $0.kind == .freeWin }.compactMap(\.potentialSavings).reduce(0, +)
        let tradeoffSavings = insights.filter { $0.kind == .tradeoff }.compactMap(\.potentialSavings).reduce(0, +)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    StatTile(title: model.plan.costLabel, value: Fmt.usd(summary.cost.total), caption: model.period.title)
                    StatTile(title: L("Доля кэша"), value: summary.requests > 0 ? Fmt.percent(summary.tokens.cacheHitRate) : "—", caption: L("чем выше, тем дешевле каждый ход"))
                    StatTile(
                        title: L("Без потери качества"),
                        value: freeSavings > 0 ? L("до \(Fmt.usd(freeSavings))") : "—",
                        caption: tradeoffSavings > 0 ? L("ещё до \(Fmt.usd(tradeoffSavings)) через компромиссы; оценки пересекаются") : L("кэш и гигиена контекста")
                    )
                    StatTile(title: L("Замечаний"), value: "\(insights.filter { $0.severity >= .info }.count)", caption: L("\(insights.filter { $0.severity >= .warning }.count) требуют внимания"))
                }

                if model.plan.isSubscription {
                    Label(L("На подписке экономия означает не деньги, а более медленный расход лимита 5-часового окна и недельного лимита."), systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                RequestHealthCard(events: events)

                if insights.isEmpty {
                    ContentUnavailableView(L("Нет данных для анализа"), systemImage: "lightbulb", description: Text(L("Выберите период, в котором были сессии Claude Code.")))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ForEach(insights) { insight in
                        InsightCard(insight: insight)
                    }
                }
            }
            .padding(20)
        }
    }
}

struct InsightCard: View {
    let insight: Insight

    var body: some View {
        let color = Palette.color(for: insight.severity)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: Palette.icon(for: insight.severity))
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(insight.title).font(.headline)
                    Text(insight.severity.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.15)))
                    Text(insight.kind.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let metric = insight.metric {
                        Text(metric).font(.title3.weight(.semibold)).monospacedDigit()
                    }
                }
                Text(insight.detail)
                    .fixedSize(horizontal: false, vertical: true)
                if let recommendation = insight.recommendation {
                    Text(recommendation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let savings = insight.potentialSavings, savings > 0 {
                    Label(L("Потенциальная экономия: до \(Fmt.usd(savings)) за период"), systemImage: "arrow.down.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Palette.good)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }
}
