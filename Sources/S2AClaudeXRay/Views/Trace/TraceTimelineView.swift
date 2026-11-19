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
            case .tenMinutes: return L("10 мин")
            case .thirtyMinutes: return L("30 мин")
            case .twoHours: return L("2 часа")
            case .session: return L("Вся сессия")
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

    static var statusDomain: [String] { [L("Модель"), L("Успех"), L("Ошибка"), L("Выполняется")] }

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
                    Picker(L("Окно"), selection: $range) {
                        ForEach(TimelineRange.allCases) { range in Text(range.title).tag(range) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 380)
                    Spacer()
                    Text(isLive ? L("обновляется в реальном времени") : L("сессия неактивна, показан её конец"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card(title: L("Что происходило"), subtitle: L("ответы модели и инструменты; пунктир — ваши промпты")) {
                    if bars.isEmpty {
                        Text(L("В этом окне ничего не происходило")).foregroundStyle(.secondary).frame(height: 80)
                    } else {
                        gantt(bars: bars, lanes: lanes, prompts: prompts, start: start, end: reference)
                    }
                }

                Card(title: L("Контекст на каждом запросе"), subtitle: L("токенов в промпте")) {
                    ContextLineChart(usage: usage, start: start, end: reference)
                }

                Card(title: L("Куда ушло время сессии")) {
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
            tooltipRows.append((label: L("Ожидание"), value: "—", color: nil))
        }

        return Chart {
            ForEach(bars) { bar in
                BarMark(
                    xStart: .value(L("Начало"), bar.start),
                    xEnd: .value(L("Конец"), bar.end),
                    y: .value(L("Дорожка"), bar.lane),
                    height: .fixed(13)
                )
                .foregroundStyle(by: .value(L("Статус"), bar.status))
                .cornerRadius(3)
            }
            ForEach(prompts) { prompt in
                RuleMark(x: .value(L("Промпт"), prompt.timestamp))
                    .foregroundStyle(Palette.user)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let hovered {
                RuleMark(x: .value(L("Время"), hovered))
                    .foregroundStyle(Palette.other.opacity(0.6))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(title: hovered.localized(date: .omitted, time: .standard), rows: tooltipRows)
                    }
            }
        }
        .chartForegroundStyleScale(domain: Self.statusDomain, range: [Palette.model, Palette.tool, Palette.critical, Palette.warning])
        .chartXScale(domain: start...end)
        .chartYScale(domain: lanes)
        .chartXSelection(value: $hovered)
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel(format: .dateTime.hour().minute().second().locale(L10n.locale))
            }
        }
        .frame(height: CGFloat(lanes.count) * 28 + 60)
    }

    private func color(for status: String) -> Color? {
        switch status {
        case L("Модель"): return Palette.model
        case L("Успех"): return Palette.tool
        case L("Ошибка"): return Palette.critical
        case L("Выполняется"): return Palette.warning
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
            let model = step.model.map(ModelCatalog.displayName(for:)) ?? L("модель")
            let thinking = step.thinkingMs > 0 ? L(", думал \(Fmt.ms(step.thinkingMs))") : ""
            bars.append(Bar(
                id: "step|\(step.messageID)",
                lane: step.isSidechain ? L("Модель · субагент") : L("Модель"),
                start: s, end: e, status: L("Модель"),
                label: "\(model) · \(Fmt.shortDuration(step.duration))\(thinking)"
            ))
        }
        for tool in trace.tools {
            guard let (s, e) = clamp(tool.start, tool.end ?? now) else { continue }
            let status = tool.isRunning ? L("Выполняется") : (tool.isError ? L("Ошибка") : L("Успех"))
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
        for fixed in [L("Модель"), L("Модель · субагент")] where bars.contains(where: { $0.lane == fixed }) {
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
            .map { Point(id: $0.id, time: $0.event.timestamp, tokens: Double($0.event.tokens.contextTokens), series: $0.event.isSidechain ? L("Субагент") : L("Основная сессия")) }

        if points.isEmpty {
            Text(L("Нет запросов в этом окне")).foregroundStyle(.secondary).frame(height: 60)
        } else {
            Chart(points) { point in
                LineMark(x: .value(L("Время"), point.time), y: .value(L("Контекст"), point.tokens))
                    .foregroundStyle(by: .value(L("Поток"), point.series))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value(L("Время"), point.time), y: .value(L("Контекст"), point.tokens))
                    .foregroundStyle(by: .value(L("Поток"), point.series))
                    .symbolSize(18)
            }
            .chartForegroundStyleScale(domain: [L("Основная сессия"), L("Субагент")], range: [Palette.model, Palette.subagent])
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
            StatTile(title: L("Модель отвечала"), value: Fmt.shortDuration(model), caption: L("из них размышления \(Fmt.shortDuration(thinking))"), systemImage: "brain")
            StatTile(title: L("Инструменты работали"), value: Fmt.shortDuration(tools), caption: L("\(trace.tools.count) вызовов"), systemImage: "wrench.and.screwdriver")
            StatTile(title: L("Субагенты"), value: Fmt.shortDuration(agents), caption: L("\(trace.subagents.reduce(0) { $0 + $1.calls }) запусков"), systemImage: "person.2")
            StatTile(title: L("Ожидание вас"), value: Fmt.shortDuration(waiting), caption: L("между ответом и следующим промптом"), systemImage: "person")
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
