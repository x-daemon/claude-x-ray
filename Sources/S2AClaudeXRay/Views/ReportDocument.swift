import Charts
import SwiftUI
import XRayCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The visual report for the selected period. Shown on the Reports screen and rendered to PDF.
struct ReportDocument: View {
    @Environment(AppModel.self) private var model
    /// Rendering for a file: no hover hints.
    var forExport = false

    var body: some View {
        let events = model.periodEvents
        let summary = UsageSummary.of(events)
        let previousEvents = model.previousPeriodEvents
        let previous = previousEvents.map { UsageSummary.of($0) }
        let sessions = SessionAnalytics.sessions(events)
        let previousSessions = previousEvents.map { Set($0.map(\.event.sessionID)).count }

        VStack(alignment: .leading, spacing: 16) {
            ReportCover(summary: summary, previous: previous)

            if summary.requests == 0 {
                Card(title: L("Нет данных")) {
                    Text(L("За выбранный период запросов не было. Выберите другой период вверху окна."))
                        .foregroundStyle(.secondary)
                }
            } else {
                ReportKPIRow(summary: summary, previous: previous, sessions: sessions.count, previousSessions: previousSessions)

                if let interval = model.periodInterval {
                    let unit = model.periodChartUnit
                    Card(title: L("Расход \(Self.unitTitle(unit))"), subtitle: L("\(model.plan.costLabel), по моделям")) {
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
                    Card(title: L("Модели"), subtitle: L("доля расхода")) {
                        RankedBarList(rows: modelRows(events, total: summary.cost.total), labelWidth: 120)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    Card(title: L("Проекты"), subtitle: L("по расходу")) {
                        RankedBarList(rows: projectRows(events, total: summary.cost.total), labelWidth: 170)
                    }
                    Card(title: L("Самые дорогие сессии")) {
                        RankedBarList(rows: sessionRows(sessions), labelWidth: 230)
                    }
                }

                if let interval = model.periodInterval {
                    let days = Self.daily(events, interval: interval)
                    if days.count >= 2 {
                        HStack(alignment: .top, spacing: 16) {
                            Card(title: L("Доля контекста из кэша"), subtitle: L("по дням")) {
                                DailyMetricChart(points: days.map { DailyPoint(day: $0.day, value: $0.cacheRate) }, domain: 0...1, format: { Fmt.percent($0) })
                            }
                            Card(title: L("Средний размер контекста"), subtitle: L("токенов на запрос, по дням")) {
                                let maxContext = days.map(\.context).max() ?? 1
                                DailyMetricChart(points: days.map { DailyPoint(day: $0.day, value: $0.context) }, domain: 0...(maxContext * 1.15), format: { Fmt.tokens(Int($0)) })
                            }
                        }
                    }
                }

                Card(title: L("Когда вы работаете"), subtitle: L("\(model.plan.costLabel) по дням недели и часам")) {
                    let cells = Analytics.heatmap(events)
                    VStack(alignment: .leading, spacing: 8) {
                        ActivityHeatmap(cells: cells, showsHint: !forExport)
                        Text(Self.rhythm(cells, total: summary.cost.total))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                RequestHealthCard(events: events)

                ReportInsights(events: events)
            }

            ReportFooter()
        }
    }

    // MARK: Rows

    private func modelRows(_ events: [PricedEvent], total: Double) -> [RankedBarRow] {
        let groups = Analytics.group(events) { model.seriesName(for: $0) }.sorted { $0.cost > $1.cost }
        let scale = model.colorScale(for: groups.map(\.key))
        return groups.map { group in
            let color = scale.domain.firstIndex(of: group.key).map { scale.range[$0] } ?? Palette.other
            return RankedBarRow(
                id: group.key,
                label: group.key,
                detail: "\(Fmt.plural(group.requests, "запрос", "запроса", "запросов"))",
                value: group.cost,
                valueText: "\(Fmt.usd(group.cost)) · \(Fmt.percent(group.cost / max(total, .leastNonzeroMagnitude)))",
                color: color
            )
        }
    }

    private func projectRows(_ events: [PricedEvent], total: Double) -> [RankedBarRow] {
        let groups = Analytics.group(events) { $0.projectName }.sorted { $0.cost > $1.cost }
        var rows = groups.prefix(7).map { group in
            RankedBarRow(
                id: group.key,
                label: group.key,
                detail: L("\(Fmt.plural(group.requests, "запрос", "запроса", "запросов")) · кэш \(Fmt.percent(group.summary.tokens.cacheHitRate))"),
                value: group.cost,
                valueText: "\(Fmt.usd(group.cost)) · \(Fmt.percent(group.cost / max(total, .leastNonzeroMagnitude)))"
            )
        }
        let rest = groups.dropFirst(7)
        if !rest.isEmpty {
            let cost = rest.reduce(0) { $0 + $1.cost }
            rows.append(RankedBarRow(
                id: "__other",
                label: L("Другие (\(rest.count))"),
                value: cost,
                valueText: "\(Fmt.usd(cost)) · \(Fmt.percent(cost / max(total, .leastNonzeroMagnitude)))",
                color: Palette.other
            ))
        }
        return rows
    }

    private func sessionRows(_ sessions: [SessionSummary]) -> [RankedBarRow] {
        sessions.sorted { $0.cost > $1.cost }.prefix(6).map { session in
            RankedBarRow(
                id: session.id,
                label: "\(session.projectName) · \(Fmt.dateTime(session.start))",
                detail: L("\(Fmt.plural(session.requests, "запрос", "запроса", "запросов")) · пик контекста \(Fmt.tokens(session.peakContextTokens)) · \(Fmt.duration(session.duration))"),
                value: session.cost,
                valueText: Fmt.usd(session.cost)
            )
        }
    }

    // MARK: Helpers

    static func unitTitle(_ unit: Calendar.Component) -> String {
        switch unit {
        case .hour: return L("по часам")
        case .weekOfYear: return L("по неделям")
        default: return L("по дням")
        }
    }

    struct Day {
        let day: Date
        let cacheRate: Double
        let context: Double
    }

    /// Days of the period that had requests: cache share and average context.
    static func daily(_ events: [PricedEvent], interval: DateInterval) -> [Day] {
        Analytics.buckets(events, unit: .day, interval: interval) { _ in "all" }
            .filter { $0.summary.requests > 0 }
            .map { Day(day: $0.start, cacheRate: $0.summary.tokens.cacheHitRate, context: $0.summary.averageContextTokens) }
    }

    /// "Чаще всего по средам (34% расхода); пиковый час — 14:00–15:00."
    static func rhythm(_ cells: [HeatCell], total: Double) -> String {
        guard total > 0 else { return "" }
        let days = [L("понедельникам"), L("вторникам"), L("средам"), L("четвергам"), L("пятницам"), L("субботам"), L("воскресеньям")]
        var byDay = [Double](repeating: 0, count: 7)
        var byHour = [Double](repeating: 0, count: 24)
        for cell in cells {
            byDay[cell.weekday] += cell.cost
            byHour[cell.hour] += cell.cost
        }
        guard let day = byDay.indices.max(by: { byDay[$0] < byDay[$1] }),
              let hour = byHour.indices.max(by: { byHour[$0] < byHour[$1] }) else { return "" }
        return L("Больше всего расходуется по \(days[day]) (\(Fmt.percent(byDay[day] / total))), пиковый час — \(String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)).")
    }
}

/// Brand band with the period and the one hero number.
struct ReportCover: View {
    @Environment(AppModel.self) private var model
    let summary: UsageSummary
    let previous: UsageSummary?

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.18))
                        Image(systemName: "waveform.path.ecg").font(.system(size: 15, weight: .bold))
                    }
                    .frame(width: 28, height: 28)
                    Text("S2A Claude X-Ray").font(.headline)
                }
                Text(L("Отчёт об использовании Claude Code"))
                    .font(.system(size: 26, weight: .bold))
                Text(periodLine)
                    .font(.callout)
                    .opacity(0.88)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.usd(summary.cost.total))
                    .font(.system(size: 52, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(model.plan.costLabel)
                    .font(.callout)
                    .opacity(0.88)
                if let previous, let change = ReportKPIRow.change(summary.cost.total, previous.cost.total) {
                    Label(L("\(change >= 0 ? "+" : "−")\(Fmt.percent(abs(change))) к прошлому периоду"), systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.brandGradient))
    }

    private var periodLine: String {
        var parts: [String] = []
        if let interval = model.periodInterval {
            parts.append("\(Self.day(interval.start)) – \(Self.day(interval.end.addingTimeInterval(-1)))")
        }
        parts.append(model.period.title)
        if model.plan.isSubscription {
            parts.append(L("подписка \(model.plan.title)"))
        }
        return parts.joined(separator: " · ")
    }

    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02ld.%02ld.%04ld", c.day ?? 0, c.month ?? 0, c.year ?? 0)
    }
}

/// Headline numbers with the change against the previous period of the same length.
struct ReportKPIRow: View {
    let summary: UsageSummary
    let previous: UsageSummary?
    let sessions: Int
    let previousSessions: Int?

    var body: some View {
        let costPerSession = sessions > 0 ? summary.cost.total / Double(sessions) : 0
        let previousCostPerSession = previous.flatMap { previous in
            previousSessions.flatMap { $0 > 0 ? previous.cost.total / Double($0) : nil }
        }
        HStack(spacing: 12) {
            ReportStatTile(title: L("Токены"), value: Fmt.tokens(summary.tokens.total),
                           change: previous.flatMap { Self.change(Double(summary.tokens.total), Double($0.tokens.total)) })
            ReportStatTile(title: L("Запросы"), value: "\(summary.requests)",
                           change: previous.flatMap { Self.change(Double(summary.requests), Double($0.requests)) })
            ReportStatTile(title: L("Сессии"), value: "\(sessions)",
                           change: previousSessions.flatMap { Self.change(Double(sessions), Double($0)) })
            ReportStatTile(title: L("Доля кэша"), value: Fmt.percent(summary.tokens.cacheHitRate),
                           change: previous.flatMap { $0.requests > 0 ? summary.tokens.cacheHitRate - $0.tokens.cacheHitRate : nil },
                           changeIsPoints: true, upIsGood: true)
            ReportStatTile(title: L("Средняя сессия"), value: Fmt.usd(costPerSession),
                           change: previousCostPerSession.flatMap { Self.change(costPerSession, $0) },
                           upIsGood: false)
        }
    }

    /// Relative change, nil without a base to compare with.
    static func change(_ current: Double, _ previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }
}

/// Stat tile with a signed change; the color says whether the change is good, when that is known.
struct ReportStatTile: View {
    let title: String
    let value: String
    var change: Double?
    /// The change is a difference of shares (percentage points), not a relative change.
    var changeIsPoints = false
    /// nil: neither direction is better.
    var upIsGood: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let change, abs(change) >= 0.0005 {
                Label(changeText(change), systemImage: change > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color(change))
            } else {
                Text(change == nil ? L("нет данных для сравнения") : L("без изменений"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }

    private func changeText(_ change: Double) -> String {
        let sign = change > 0 ? "+" : "−"
        if changeIsPoints {
            let points = String(format: "%.1f", abs(change) * 100).replacingOccurrences(of: ".", with: ",")
            return L("\(sign)\(points) п.п. к прошлому периоду")
        }
        return L("\(sign)\(Fmt.percent(abs(change))) к прошлому периоду")
    }

    private func color(_ change: Double) -> Color {
        guard let upIsGood else { return .secondary }
        return (change > 0) == upIsGood ? Palette.good : Palette.critical
    }
}

struct DailyPoint: Identifiable {
    let day: Date
    let value: Double
    var id: Date { day }
}

/// One measure per day: a 2 px line over a light wash, the latest value labelled.
struct DailyMetricChart: View {
    let points: [DailyPoint]
    let domain: ClosedRange<Double>
    let format: (Double) -> String
    var color: Color = Palette.primary

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value(L("День"), point.day, unit: .day), yStart: .value(L("Ноль"), domain.lowerBound), yEnd: .value(L("Значение"), point.value))
                    .foregroundStyle(color.opacity(0.10))
                    .interpolationMethod(.monotone)
                LineMark(x: .value(L("День"), point.day, unit: .day), y: .value(L("Значение"), point.value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = points.last {
                PointMark(x: .value(L("День"), last.day, unit: .day), y: .value(L("Значение"), last.value))
                    .symbolSize(150)
                    .foregroundStyle(Palette.card)
                PointMark(x: .value(L("День"), last.day, unit: .day), y: .value(L("Значение"), last.value))
                    .symbolSize(64)
                    .foregroundStyle(color)
                    .annotation(position: .top, alignment: .trailing, spacing: 6) {
                        Text(format(last.value)).font(.caption.weight(.semibold))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(format(amount)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel(format: .dateTime.day().month(.twoDigits).locale(L10n.locale))
            }
        }
        .frame(height: 170)
    }
}

/// Recommendations, the ones that keep quality first, with the savings they promise.
struct ReportInsights: View {
    @Environment(AppModel.self) private var model
    let events: [PricedEvent]

    var body: some View {
        let insights = InsightEngine(pricing: model.pricing).analyze(events)
        let freeWins = insights.filter { $0.kind == .freeWin }.compactMap(\.potentialSavings).reduce(0, +)
        Card(title: L("Рекомендации"), subtitle: freeWins > 0 ? L("без потери качества можно сэкономить до \(Fmt.usd(freeWins))") : nil) {
            if insights.isEmpty {
                Text(L("Замечаний нет: расход выглядит сбалансированным."))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(insights) { insight in
                        InsightCard(insight: insight)
                    }
                }
            }
        }
    }
}

struct ReportFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        var parts = [L("Суммы — API-эквивалент по прайс-листу Anthropic")]
        if model.plan.isSubscription {
            parts[0] += L(": на подписке \(model.plan.title) деньги не списываются")
        }
        #if os(macOS)
        parts.append(L("Источники: логи Claude Code на этом Mac, импортированные логи и логи, присланные облачными сессиями"))
        #else
        parts.append(L("Источники: логи Claude Code с ваших компьютеров, включая облачные сессии, которые они получили"))
        #endif
        parts.append(L("Сформировано \(Fmt.dateTime(model.now)) в S2A Claude X-Ray"))
        return parts.joined(separator: ". ") + "."
    }
}

/// Renders the report to a one-page PDF on light paper.
@MainActor
enum ReportPDF {
    static func data(for model: AppModel, width: CGFloat = 1040) -> Data? {
        let content = ReportDocument(forExport: true)
            .environment(model)
            .environment(\.colorScheme, .light)
            .frame(width: width)
            .padding(32)
            .background(Palette.page ?? Color.white)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width + 64, height: nil)
        let data = NSMutableData()
        var rendered = false
        let draw = {
            renderer.render { size, render in
                var box = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: data as CFMutableData),
                      let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
                context.beginPDFPage(nil)
                render(context)
                context.endPDFPage()
                context.closePDF()
                rendered = true
            }
        }
        // Theme colors follow the appearance they are drawn in: paper is light.
        #if os(macOS)
        if let light = NSAppearance(named: .aqua) {
            light.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        #else
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent(draw)
        #endif
        return rendered ? data as Data : nil
    }
}
