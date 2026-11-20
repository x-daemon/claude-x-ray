import Charts
import SwiftUI
import XRayCore

/// Static analysis of the selected period: totals, timeline, cost structure, heatmap, model share.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let events = model.periodEvents
        let summary = UsageSummary.of(events)
        let sessions = Set(events.map(\.event.sessionID)).count
        let unit = model.periodChartUnit

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatTile(title: model.plan.costLabel, value: Fmt.usd(summary.cost.total), caption: model.period.title, systemImage: "dollarsign.circle")
                    StatTile(title: L("Токены"), value: Fmt.tokens(summary.tokens.total), caption: L("вывод \(Fmt.tokens(summary.tokens.output)), из них размышления \(Fmt.tokens(summary.tokens.thinking))"), systemImage: "number")
                    StatTile(title: L("Запросы"), value: "\(summary.requests)", caption: L("\(sessions) сессий · \(Fmt.usd(summary.costPerRequest)) за запрос"), systemImage: "arrow.up.arrow.down")
                    StatTile(title: L("Доля кэша"), value: summary.requests > 0 ? Fmt.percent(summary.tokens.cacheHitRate) : "—", caption: L("средний контекст \(Fmt.tokens(Int(summary.averageContextTokens)))"), systemImage: "memorychip")
                }

                if let interval = model.periodInterval {
                    Card(title: L("Стоимость по времени"), subtitle: L("по моделям · \(unitTitle(unit))")) {
                        CostTimelineChart(
                            buckets: Analytics.buckets(events, unit: unit, interval: interval) { model.seriesName(for: $0) },
                            unit: unit,
                            interval: interval
                        )
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    Card(title: L("Из чего складывается стоимость")) {
                        CostCompositionView(summary: summary)
                    }
                    Card(title: L("Доля моделей")) {
                        ModelShareChart(events: events)
                    }
                    .frame(maxWidth: 420)
                }

                Card(title: L("Когда вы работаете"), subtitle: L("\(model.plan.costLabel) по дням недели и часам")) {
                    ActivityHeatmap(cells: Analytics.heatmap(events))
                }
            }
            .padding(20)
        }
    }

    private func unitTitle(_ unit: Calendar.Component) -> String {
        switch unit {
        case .hour: return L("по часам")
        case .weekOfYear: return L("по неделям")
        default: return L("по дням")
        }
    }
}

/// Stacked bars per time bucket, one segment per model, with a hover breakdown.
struct CostTimelineChart: View {
    @Environment(AppModel.self) private var model
    let buckets: [TimeBucket]
    let unit: Calendar.Component
    let interval: DateInterval
    @State private var selected: Date?

    private struct Point: Identifiable {
        let date: Date
        let series: String
        let cost: Double
        var id: String { "\(date.timeIntervalSince1970)-\(series)" }
    }

    var body: some View {
        // Same stacking order in every bucket: by the model's all-time rank.
        let order = model.modelOrder + [AppModel.otherSeries]
        let points = buckets.flatMap { bucket in
            bucket.bySeries
                .map { Point(date: bucket.start, series: $0.key, cost: $0.value.cost.total) }
                .sorted { (order.firstIndex(of: $0.series) ?? Int.max) < (order.firstIndex(of: $1.series) ?? Int.max) }
        }
        let scale = model.colorScale(for: points.map(\.series))
        let selectedBucket = selected.flatMap { date in buckets.first { $0.start <= date && date < $0.end } }
        // Thin bars leave air between days; past ~40 buckets they share the slot instead.
        let barWidth: MarkDimension = buckets.count <= 40 ? .fixed(20) : .ratio(0.8)

        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value(L("Дата"), point.date, unit: unit),
                    y: .value("USD", point.cost),
                    width: barWidth
                )
                .foregroundStyle(by: .value(L("Модель"), point.series))
            }
            if let bucket = selectedBucket {
                RuleMark(x: .value(L("Дата"), bucket.start, unit: unit))
                    .foregroundStyle(Palette.other.opacity(0.35))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(for: bucket, scale: scale)
                    }
            }
        }
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartXScale(domain: interval.start...interval.end)
        .chartXSelection(value: $selected)
        .chartLegend(position: .bottom, alignment: .leading)
        .usdYAxis()
        .frame(height: 260)
        .overlay {
            if points.isEmpty {
                Text(L("Нет данных за период")).foregroundStyle(.secondary)
            }
        }
    }

    private func tooltip(for bucket: TimeBucket, scale: (domain: [String], range: [Color])) -> some View {
        let title: String
        switch unit {
        case .hour: title = bucket.start.localized(date: .abbreviated, time: .shortened)
        default: title = bucket.start.localized(date: .abbreviated, time: .omitted)
        }
        var rows: [(label: String, value: String, color: Color?)] = [(L("Всего"), Fmt.usd(bucket.summary.cost.total), nil)]
        for (name, summary) in bucket.bySeries.sorted(by: { $0.value.cost.total > $1.value.cost.total }) {
            let color = scale.domain.firstIndex(of: name).map { scale.range[$0] }
            rows.append((name, Fmt.usd(summary.cost.total), color))
        }
        rows.append((L("Токены"), Fmt.tokens(bucket.summary.tokens.total), nil))
        return ChartTooltip(title: title, rows: rows)
    }
}

/// One stacked bar of the cost split by component, plus the numbers behind it.
struct CostCompositionView: View {
    let summary: UsageSummary

    private struct Component: Identifiable {
        let name: String
        let cost: Double
        let tokens: Int?
        var id: String { name }
    }

    var body: some View {
        let components = [
            Component(name: L("Ввод"), cost: summary.cost.input, tokens: summary.tokens.input),
            Component(name: L("Вывод"), cost: summary.cost.output, tokens: summary.tokens.output),
            Component(name: L("Чтение кэша"), cost: summary.cost.cacheRead, tokens: summary.tokens.cacheRead),
            Component(name: L("Запись в кэш"), cost: summary.cost.cacheWrite, tokens: summary.tokens.cacheWrite),
            Component(name: L("Веб-поиск"), cost: summary.cost.webSearch, tokens: nil),
        ].filter { $0.cost > 0 }
        let total = max(summary.cost.total, .leastNonzeroMagnitude)
        let domain = components.map(\.name)
        let range = domain.compactMap { name in Palette.componentOrder.firstIndex(of: name).map { Palette.componentColors[$0] } }

        VStack(alignment: .leading, spacing: 12) {
            Chart(components) { component in
                BarMark(x: .value("USD", component.cost), y: .value(L("Итого"), L("Стоимость")))
                    .foregroundStyle(by: .value(L("Статья"), component.name))
            }
            .chartForegroundStyleScale(domain: domain, range: range)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(Fmt.usd(amount)) }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 56)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(components.enumerated()), id: \.element.id) { index, component in
                    GridRow {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index < range.count ? range[index] : Palette.other)
                            .frame(width: 10, height: 10)
                        Text(component.name)
                        Text(component.tokens.map { Fmt.tokens($0) } ?? "—").foregroundStyle(.secondary)
                        Text(Fmt.usd(component.cost)).monospacedDigit()
                        Text(Fmt.percent(component.cost / total)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            if summary.tokens.thinking > 0 {
                Text(L("Размышления — \(Fmt.percent(Double(summary.tokens.thinking) / Double(max(summary.tokens.output, 1)))) выходных токенов; они оплачиваются как вывод."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Donut of cost by model with stable model colors.
struct ModelShareChart: View {
    @Environment(AppModel.self) private var model
    let events: [PricedEvent]

    var body: some View {
        let groups = Analytics.group(events) { model.seriesName(for: $0) }
        let scale = model.colorScale(for: groups.map(\.key))

        Chart(groups) { group in
            SectorMark(angle: .value("USD", group.cost), innerRadius: .ratio(0.62), angularInset: 1.5)
                .foregroundStyle(by: .value(L("Модель"), group.key))
                .cornerRadius(4)
        }
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartLegend(position: .trailing, alignment: .center)
        .frame(height: 200)
        .overlay {
            if groups.isEmpty {
                Text(L("Нет данных")).foregroundStyle(.secondary)
            }
        }
    }
}

/// Weekday x hour grid of API-equivalent spend, with a hover readout.
struct ActivityHeatmap: View {
    let cells: [HeatCell]
    var showsHint = true
    @State private var hovered: HeatCell?

    private static var days: [String] { [L("Пн"), L("Вт"), L("Ср"), L("Чт"), L("Пт"), L("Сб"), L("Вс")] }
    private static let hours = (0..<24).map { String(format: "%02d", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(cells) { cell in
                    if cell.cost > 0 {
                        RectangleMark(
                            x: .value(L("Час"), Self.hours[cell.hour]),
                            y: .value(L("День"), Self.days[cell.weekday]),
                            width: .ratio(0.9),
                            height: .ratio(0.9)
                        )
                        .foregroundStyle(by: .value("USD", cell.cost))
                        .cornerRadius(3)
                    } else {
                        RectangleMark(
                            x: .value(L("Час"), Self.hours[cell.hour]),
                            y: .value(L("День"), Self.days[cell.weekday]),
                            width: .ratio(0.9),
                            height: .ratio(0.9)
                        )
                        .foregroundStyle(Palette.emptyCell)
                        .cornerRadius(3)
                    }
                }
            }
            .chartForegroundStyleScale(range: Gradient(colors: Palette.sequential))
            .chartLegend(.hidden)
            .chartXScale(domain: Self.hours)
            .chartYScale(domain: Self.days)
            .chartXAxis {
                AxisMarks(values: stride(from: 0, to: 24, by: 3).map { Self.hours[$0] }) { _ in
                    AxisValueLabel()
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hovered = cell(at: location, proxy: proxy, geometry: geometry)
                            case .ended:
                                hovered = nil
                            }
                        }
                        #if os(iOS)
                        // Touch: a tap shows the cell's value (a drag would stop the page scrolling).
                        .onTapGesture { location in
                            hovered = cell(at: location, proxy: proxy, geometry: geometry)
                        }
                        #endif
                }
            }
            .frame(height: 220)

            HStack(spacing: 6) {
                Text(L("меньше"))
                HStack(spacing: 2) {
                    ForEach(Array(Palette.sequential.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 16, height: 9)
                    }
                }
                Text(L("больше · до \(Fmt.usd(cells.map(\.cost).max() ?? 0)) за час"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if showsHint {
                Group {
                    if let hovered {
                        Text(L("\(Self.days[hovered.weekday]), \(Self.hours[hovered.hour]):00 — \(Fmt.usd(hovered.cost)), запросов: \(hovered.requests)"))
                    } else {
                        Text(hint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var hint: String {
        #if os(macOS)
        return L("Наведите курсор на ячейку, чтобы увидеть значение.")
        #else
        return L("Коснитесь ячейки, чтобы увидеть значение.")
        #endif
    }

    private func cell(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> HeatCell? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geometry[anchor]
        let x = location.x - frame.origin.x
        let y = location.y - frame.origin.y
        guard let hour = proxy.value(atX: x, as: String.self),
              let day = proxy.value(atY: y, as: String.self),
              let hourIndex = Self.hours.firstIndex(of: hour),
              let dayIndex = Self.days.firstIndex(of: day) else { return nil }
        return cells.first { $0.weekday == dayIndex && $0.hour == hourIndex }
    }
}
