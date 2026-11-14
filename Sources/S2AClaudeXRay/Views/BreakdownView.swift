import Charts
import SwiftUI
import XRayCore

enum BreakdownDimension {
    case project, model

    var title: String {
        switch self {
        case .project: return "Проект"
        case .model: return "Модель"
        }
    }

    var chartTitle: String {
        switch self {
        case .project: return "Самые дорогие проекты"
        case .model: return "Стоимость по моделям"
        }
    }

    func key(_ event: UsageEvent) -> String {
        switch self {
        case .project: return event.projectPath
        case .model: return event.model
        }
    }
}

/// One row of the breakdown table.
struct BreakdownRow: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let requests: Int
    let tokens: Int
    let cacheHitRate: Double
    let thinkingShare: Double
    let cost: Double
    let share: Double
}

/// Cost per project or per model: a ranked bar chart and a sortable table.
struct BreakdownView: View {
    @Environment(AppModel.self) private var model
    let dimension: BreakdownDimension
    @State private var sortOrder = [KeyPathComparator(\BreakdownRow.cost, order: .reverse)]

    var body: some View {
        let events = model.periodEvents
        let groups = Analytics.group(events) { dimension.key($0) }
        let total = max(groups.reduce(0) { $0 + $1.cost }, .leastNonzeroMagnitude)
        let names = displayNames(for: groups.map(\.key))
        let rows = groups.map { group in
            let tokens = group.summary.tokens
            return BreakdownRow(
                id: group.key,
                name: names[group.key] ?? group.key,
                detail: group.key,
                requests: group.requests,
                tokens: group.totalTokens,
                cacheHitRate: group.cacheHitRate,
                thinkingShare: tokens.output > 0 ? Double(tokens.thinking) / Double(tokens.output) : 0,
                cost: group.cost,
                share: group.cost / total
            )
        }
        let top = Array(rows.sorted { $0.cost > $1.cost }.prefix(10))

        VStack(spacing: 0) {
            Card(title: dimension.chartTitle, subtitle: "\(model.plan.costLabel) · \(model.period.title)") {
                rankedChart(top)
            }
            .padding(16)

            Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
                TableColumn(dimension.title, value: \.name) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                        if row.detail != row.name {
                            Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Запросы", value: \.requests) { row in Text("\(row.requests)").monospacedDigit() }
                TableColumn("Токены", value: \.tokens) { row in Text(Fmt.tokens(row.tokens)).monospacedDigit() }
                TableColumn("Кэш", value: \.cacheHitRate) { row in Text(Fmt.percent(row.cacheHitRate)).monospacedDigit() }
                TableColumn("Размышления", value: \.thinkingShare) { row in Text(Fmt.percent(row.thinkingShare)).monospacedDigit() }
                TableColumn("USD", value: \.cost) { row in Text(Fmt.usd(row.cost)).monospacedDigit() }
                TableColumn("Доля", value: \.share) { row in Text(Fmt.percent(row.share)).monospacedDigit() }
            }
        }
    }

    @ViewBuilder
    private func rankedChart(_ top: [BreakdownRow]) -> some View {
        if top.isEmpty {
            Text("Нет данных за период").foregroundStyle(.secondary).frame(height: 120)
        } else {
            let scale = modelScale(for: top.map(\.name))
            RankedBarList(rows: top.map { row in
                var color = Palette.primary
                if dimension == .model {
                    let series = scale.domain.contains(row.name) ? row.name : AppModel.otherSeries
                    color = scale.domain.firstIndex(of: series).map { scale.range[$0] } ?? Palette.other
                }
                return RankedBarRow(
                    id: row.id,
                    label: row.name,
                    detail: row.detail == row.name ? nil : row.detail,
                    value: row.cost,
                    valueText: "\(Fmt.usd(row.cost)) · \(Fmt.percent(row.share))",
                    color: color
                )
            })
        }
    }

    /// Stable model colors; models past the colored slots share the "other" color.
    private func modelScale(for names: [String]) -> (domain: [String], range: [Color]) {
        var scale = model.colorScale(for: names)
        let colored = Set(scale.domain)
        if names.contains(where: { !colored.contains($0) }), !colored.contains(AppModel.otherSeries) {
            scale.domain.append(AppModel.otherSeries)
            scale.range.append(Palette.other)
        }
        return scale
    }

    /// Display names; projects with the same folder name get their parent folder added.
    private func displayNames(for keys: [String]) -> [String: String] {
        switch dimension {
        case .model:
            return Dictionary(keys.map { ($0, ModelCatalog.displayName(for: $0)) }, uniquingKeysWith: { first, _ in first })
        case .project:
            func last(_ path: String, _ count: Int) -> String {
                path.split(separator: "/").suffix(count).joined(separator: "/")
            }
            let short = keys.map { last($0, 1) }
            var counts: [String: Int] = [:]
            short.forEach { counts[$0, default: 0] += 1 }
            var result: [String: String] = [:]
            for (key, name) in zip(keys, short) {
                let candidate = (counts[name] ?? 0) > 1 ? last(key, 2) : name
                result[key] = candidate.isEmpty ? key : candidate
            }
            return result
        }
    }
}

extension View {
    /// X axis labelled in dollars (horizontal bar charts).
    func usdXAxis() -> some View {
        chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(Fmt.usd(amount))
                    }
                }
            }
        }
    }
}
