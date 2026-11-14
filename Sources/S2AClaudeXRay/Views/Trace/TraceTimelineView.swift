import Charts
import SwiftUI
import XRayCore

/// Gantt chart of model responses and tool runs, context growth on the same time axis,
/// and where the session's time went.
struct TraceTimelineView: View {
    let trace: SessionTrace
    let usage: [String: PricedEvent]
    @State private var range: TimelineRange = .thirtyMinutes
    @State private var hovered: Date?

    enum TimelineRange: String, CaseIterable, Identifiable {
        case tenMinutes, thirtyMinutes, twoHours, session

        var id: Self { self }

        var title: String {
            switch self {
            case .tenMinutes: return "10 мин"
            case .thirtyMinutes: return "30 мин"
            case .twoHours: return "2 часа"
            case .session: return "Вся сессия"
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .tenMinutes: return 600
            case .thirtyMinutes: return 1800
            case .twoHours: return 7200
            case .session: return nil
            }
        }
    }

    struct Bar: Identifiable {
        let id: String
        let lane: String
        let start: Date
        let end: Date
        let status: String
        let label: String
    }

    static let statusDomain = ["Модель", "Успех", "Ошибка", "Выполняется"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { timeline in
            content(now: timeline.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let isLive = trace.status?.state.isActive ?? false
        let reference = isLive ? now : max(trace.end ?? now, trace.tools.compactMap(\.end).max() ?? .distantPast)
        let sessionStart = trace.start ?? reference.addingTimeInterval(-600)
        let start = range.seconds.map { max(sessionStart, reference.addingTimeInterval(-$0)) } ?? sessionStart
        let span = max(reference.timeIntervalSince(start), 60)
        let bars = makeBars(from: start, to: reference, minWidth: span / 300, now: now)
        let lanes = laneOrder(bars)
        let prompts = trace.items.filter { $0.kind == .prompt && !$0.isSidechain && $0.timestamp >= start && $0.timestamp <= reference }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("Окно", selection: $range) {
                        ForEach(TimelineRange.allCases) { range in Text(range.title).tag(range) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 380)
                    Spacer()
                    Text(isLive ? "обновляется в реальном времени" : "сессия неактивна, показан её конец")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card(title: "Что происходило", subtitle: "ответы модели и инструменты; пунктир — ваши промпты") {
                    if bars.isEmpty {
                        Text("В этом окне ничего не происходило").foregroundStyle(.secondary).frame(height: 80)
                    } else {
                        gantt(bars: bars, lanes: lanes, prompts: prompts, start: start, end: reference)
                    }
                }

                Card(title: "Контекст на каждом запросе", subtitle: "токенов в промпте") {
                    ContextLineChart(usage: usage, start: start, end: reference)
                }

                Card(title: "Куда ушло время сессии") {
                    TimeSplitView(trace: trace, now: now)
                }
            }
            .padding(20)
        }
    }

    private func gantt(bars: [Bar], lanes: [String], prompts: [ActivityItem], start: Date, end: Date) -> some View {
        let active = hovered.map { time in bars.filter { $0.start <= time && time <= $0.end } } ?? []
        var tooltipRows: [(label: String, value: String, color: Color?)] = []
        for bar in active.prefix(6) {
            tooltipRows.append((label: bar.lane, value: bar.label, color: color(for: bar.status)))
        }
        if tooltipRows.isEmpty {
            tooltipRows.append((label: "Ожидание", value: "—", color: nil))
        }

        return Chart {
            ForEach(bars) { bar in
                BarMark(
                    xStart: .value("Начало", bar.start),
                    xEnd: .value("Конец", bar.end),
                    y: .value("Дорожка", bar.lane),
                    height: .fixed(13)
                )
                .foregroundStyle(by: .value("Статус", bar.status))
                .cornerRadius(3)
            }
            ForEach(prompts) { prompt in
                RuleMark(x: .value("Промпт", prompt.timestamp))
                    .foregroundStyle(Palette.series[1])
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let hovered {
                RuleMark(x: .value("Время", hovered))
                    .foregroundStyle(Palette.other.opacity(0.6))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(title: hovered.formatted(date: .omitted, time: .standard), rows: tooltipRows)
                    }
            }
        }
        .chartForegroundStyleScale(domain: Self.statusDomain, range: [Palette.series[0], Palette.series[2], Palette.critical, Palette.warning])
        .chartXScale(domain: start...end)
        .chartYScale(domain: lanes)
        .chartXSelection(value: $hovered)
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
        .frame(height: CGFloat(lanes.count) * 28 + 60)
    }

    private func color(for status: String) -> Color? {
        switch status {
        case "Модель": return Palette.series[0]
        case "Успех": return Palette.series[2]
        case "Ошибка": return Palette.critical
        case "Выполняется": return Palette.warning
        default: return nil
        }
    }

    private func makeBars(from start: Date, to end: Date, minWidth: TimeInterval, now: Date) -> [Bar] {
        var bars: [Bar] = []
        func clamp(_ a: Date, _ b: Date) -> (Date, Date)? {
            guard b >= start, a <= end else { return nil }
            let s = max(a, start)
            let e = min(max(b, s.addingTimeInterval(minWidth)), end.addingTimeInterval(minWidth))
            return (s, e)
        }
        for step in trace.steps {
            guard let (s, e) = clamp(step.start, step.end) else { continue }
            let model = step.model.map(ModelCatalog.displayName(for:)) ?? "модель"
            let thinking = step.thinkingMs > 0 ? ", думал \(Fmt.ms(step.thinkingMs))" : ""
            bars.append(Bar(
                id: "step|\(step.messageID)",
                lane: step.isSidechain ? "Модель · субагент" : "Модель",
                start: s, end: e, status: "Модель",
                label: "\(model) · \(Fmt.shortDuration(step.duration))\(thinking)"
            ))
        }
        for tool in trace.tools {
            guard let (s, e) = clamp(tool.start, tool.end ?? now) else { continue }
            let status = tool.isRunning ? "Выполняется" : (tool.isError ? "Ошибка" : "Успех")
            let lane = (tool.call.isSidechain ? "↳ " : "") + (tool.mcpServer.map { "MCP \($0)" } ?? tool.name)
            bars.append(Bar(
                id: "tool|\(tool.id)",
                lane: lane,
                start: s, end: e, status: status,
                label: "\(Snippet.truncate(tool.call.title, 60)) · \(Fmt.shortDuration(tool.duration(now: now)))"
            ))
        }
        return bars
    }

    /// Model lanes first, then tools by first appearance; at most 14 lanes.
    private func laneOrder(_ bars: [Bar]) -> [String] {
        var lanes: [String] = []
        for fixed in ["Модель", "Модель · субагент"] where bars.contains(where: { $0.lane == fixed }) {
            lanes.append(fixed)
        }
        for bar in bars.sorted(by: { $0.start < $1.start }) where !lanes.contains(bar.lane) {
            lanes.append(bar.lane)
        }
        return Array(lanes.prefix(14))
    }
}

/// Context tokens per request over time, with the context-window share of the latest one.
struct ContextLineChart: View {
    let usage: [String: PricedEvent]
    let start: Date
    let end: Date

    private struct Point: Identifiable {
        let id: String
        let time: Date
        let tokens: Double
        let series: String
    }

    var body: some View {
        let points = usage.values
            .filter { $0.event.timestamp >= start && $0.event.timestamp <= end }
            .sorted { $0.event.timestamp < $1.event.timestamp }
            .map { Point(id: $0.id, time: $0.event.timestamp, tokens: Double($0.event.tokens.contextTokens), series: $0.event.isSidechain ? "Субагент" : "Основная сессия") }

        if points.isEmpty {
            Text("Нет запросов в этом окне").foregroundStyle(.secondary).frame(height: 60)
        } else {
            Chart(points) { point in
                LineMark(x: .value("Время", point.time), y: .value("Контекст", point.tokens))
                    .foregroundStyle(by: .value("Поток", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Время", point.time), y: .value("Контекст", point.tokens))
                    .foregroundStyle(by: .value("Поток", point.series))
                    .symbolSize(18)
            }
            .chartForegroundStyleScale(domain: ["Основная сессия", "Субагент"], range: [Palette.series[0], Palette.series[4]])
            .chartXScale(domain: start...end)
            .tokenYAxis()
            .frame(height: 170)
        }
    }
}

/// Model time, tool time, subagents and waiting for the user.
struct TimeSplitView: View {
    let trace: SessionTrace
    let now: Date

    var body: some View {
        let model = trace.steps.filter { !$0.isSidechain }.reduce(0) { $0 + $1.duration }
        let tools = trace.tools.filter { !$0.call.isSidechain && $0.category != .agent }.reduce(0) { $0 + $1.duration(now: now) }
        let agents = trace.tools.filter { $0.category == .agent && !$0.call.isSidechain }.reduce(0) { $0 + $1.duration(now: now) }
        let waiting = waitingForUser()
        let thinking = Double(trace.steps.reduce(0) { $0 + $1.thinkingMs }) / 1000

        HStack(spacing: 12) {
            StatTile(title: "Модель отвечала", value: Fmt.shortDuration(model), caption: "из них размышления \(Fmt.shortDuration(thinking))", systemImage: "brain")
            StatTile(title: "Инструменты работали", value: Fmt.shortDuration(tools), caption: "\(trace.tools.count) вызовов", systemImage: "wrench.and.screwdriver")
            StatTile(title: "Субагенты", value: Fmt.shortDuration(agents), caption: "\(trace.subagents.reduce(0) { $0 + $1.calls }) запусков", systemImage: "person.2")
            StatTile(title: "Ожидание вас", value: Fmt.shortDuration(waiting), caption: "между ответом и следующим промптом", systemImage: "person")
        }
    }

    /// Gaps between the end of a turn and the next prompt.
    private func waitingForUser() -> TimeInterval {
        var total: TimeInterval = 0
        for (previous, next) in zip(trace.turns, trace.turns.dropFirst()) where next.prompt != nil {
            total += max(0, next.start.timeIntervalSince(previous.end))
        }
        return total
    }
}
