import Charts
import SwiftUI
import XRayCore

/// Real-time view: current 5-hour window, burn rate, live activity, current session.
struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let now = model.now
        let today = UsageSummary.of(model.todayEvents)
        let week = UsageSummary.of(model.lastSevenDaysEvents)
        let burn = Analytics.burnRate(model.priced.suffix(5_000).map { $0 }, now: now, window: 3600)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LiveActivityCard()

                Card(title: "Окно лимита (5 часов)", subtitle: model.plan.isSubscription ? "подписка \(model.plan.title)" : nil) {
                    WindowSummaryView()
                }

                HStack(spacing: 12) {
                    StatTile(
                        title: "Сегодня", value: Fmt.usd(today.cost.total),
                        caption: "\(Fmt.tokens(today.tokens.total)) токенов · \(today.requests) запросов",
                        systemImage: "sun.max"
                    )
                    StatTile(
                        title: "7 дней", value: Fmt.usd(week.cost.total),
                        caption: "\(Fmt.tokens(week.tokens.total)) токенов",
                        systemImage: "calendar"
                    )
                    StatTile(
                        title: "Темп за последний час", value: "\(Fmt.usd(burn.costPerHour))/ч",
                        caption: "\(Fmt.tokens(Int(burn.tokensPerMinute))) токенов/мин",
                        systemImage: "flame"
                    )
                    StatTile(
                        title: "Кэш сегодня", value: today.requests > 0 ? Fmt.percent(today.tokens.cacheHitRate) : "—",
                        caption: "доля контекста из кэша",
                        systemImage: "memorychip"
                    )
                }

                Card(title: "Активность за 3 часа", subtitle: "\(model.plan.costLabel), интервалы по 5 минут") {
                    LiveActivityChart(
                        buckets: Analytics.fixedBuckets(
                            model.events(since: now.addingTimeInterval(-3 * 3600)),
                            interval: DateInterval(start: now.addingTimeInterval(-3 * 3600), end: now),
                            width: 300
                        ),
                        windowStart: model.activeWindow?.start,
                        now: now
                    )
                }

                if let session = model.currentSession {
                    CurrentSessionCard(session: session, lastEvents: Array(model.priced.suffix(12).reversed()))
                }

                if model.plan.isSubscription {
                    Text("На подписке Pro/Max суммы — API-эквивалент по прайс-листу: деньги не списываются, но по ним видно, как быстро расходуется лимит. Границы окна восстанавливаются по активности; точный остаток лимита в логах не хранится.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}

/// Current window: spend, time left, pace and comparison with the personal peak.
struct WindowSummaryView: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        let now = model.now
        if let window = model.activeWindow {
            let cost = window.summary.cost.total
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.usd(cost))
                        .font(.system(size: compact ? 28 : 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(model.plan.costLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("до сброса").font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.duration(window.remaining(at: now)))
                            .font(.title3.weight(.medium))
                            .monospacedDigit()
                    }
                }

                ProgressView(value: window.progress(at: now)) {
                    Text("Время окна: \(window.start.formatted(date: .omitted, time: .shortened)) – \(window.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let peak = model.peakWindow, peak.summary.cost.total > 0 {
                    let ratio = cost / peak.summary.cost.total
                    ProgressView(value: min(ratio, 1)) {
                        Text("\(Fmt.percent(ratio)) от вашего самого загруженного окна (\(Fmt.usd(peak.summary.cost.total)), \(Fmt.dateTime(peak.start)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tint(ratio >= 0.9 ? Palette.critical : ratio >= 0.7 ? Palette.warning : Palette.series[0])
                }

                HStack(spacing: 16) {
                    Label("\(Fmt.tokens(window.summary.tokens.total)) токенов", systemImage: "number")
                    Label("\(window.summary.requests) запросов", systemImage: "arrow.up.arrow.down")
                    Label("прогноз \(Fmt.usd(window.projectedCost(at: now)))", systemImage: "chart.line.uptrend.xyaxis")
                    if !compact {
                        Label(window.models.map(ModelCatalog.displayName(for:)).joined(separator: ", "), systemImage: "cpu")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Сейчас активного окна нет").font(.headline)
                if let last = model.priced.last {
                    Text("Последний запрос: \(Fmt.dateTime(last.event.timestamp)). Новое окно начнётся с первого запроса.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Per-5-minute spend for the last three hours, with a hover tooltip.
struct LiveActivityChart: View {
    let buckets: [TimeBucket]
    let windowStart: Date?
    let now: Date
    @State private var hovered: Date?

    var body: some View {
        Chart {
            ForEach(buckets) { bucket in
                BarMark(
                    xStart: .value("Начало", bucket.start),
                    xEnd: .value("Конец", bucket.end.addingTimeInterval(-20)),
                    y: .value("USD", bucket.summary.cost.total)
                )
                .foregroundStyle(Palette.series[0])
                .cornerRadius(3)
            }
            if let windowStart, windowStart > (buckets.first?.start ?? now) {
                RuleMark(x: .value("Начало окна", windowStart))
                    .foregroundStyle(Palette.other)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("начало окна").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let hovered, let bucket = buckets.first(where: { $0.start <= hovered && hovered < $0.end }) {
                RuleMark(x: .value("Время", bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2)))
                    .foregroundStyle(Palette.other.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(
                            title: "\(bucket.start.formatted(date: .omitted, time: .shortened)) – \(bucket.end.formatted(date: .omitted, time: .shortened))",
                            rows: [
                                ("Стоимость", Fmt.usd(bucket.summary.cost.total), Palette.series[0]),
                                ("Токены", Fmt.tokens(bucket.summary.tokens.total), nil),
                                ("Запросы", "\(bucket.summary.requests)", nil),
                            ]
                        )
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 30)) { _ in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .usdYAxis()
        .frame(height: 200)
    }
}

/// The session of the latest request, plus its most recent requests.
struct CurrentSessionCard: View {
    let session: SessionSummary
    let lastEvents: [PricedEvent]

    var body: some View {
        Card(title: "Текущая сессия", subtitle: session.gitBranch.map { "\(session.projectName) · \($0)" } ?? session.projectName) {
            HStack(spacing: 12) {
                StatTile(title: "Стоимость", value: Fmt.usd(session.cost))
                StatTile(title: "Запросы", value: "\(session.requests)")
                StatTile(title: "Контекст сейчас", value: Fmt.tokens(lastEvents.first?.event.tokens.contextTokens ?? 0), caption: "пик \(Fmt.tokens(session.peakContextTokens))")
                StatTile(title: "Кэш", value: Fmt.percent(session.cacheHitRate))
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Время").foregroundStyle(.secondary)
                    Text("Модель").foregroundStyle(.secondary)
                    Text("Контекст").foregroundStyle(.secondary)
                    Text("Вывод").foregroundStyle(.secondary)
                    Text("Кэш").foregroundStyle(.secondary)
                    Text("USD").foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(lastEvents) { priced in
                    let e = priced.event
                    GridRow {
                        Text(e.timestamp.formatted(date: .omitted, time: .standard))
                        Text(ModelCatalog.displayName(for: e.model) + (e.isSidechain ? " · субагент" : ""))
                        Text(Fmt.tokens(e.tokens.contextTokens))
                        Text(Fmt.tokens(e.tokens.output))
                        Text(Fmt.percent(e.tokens.cacheHitRate))
                        Text(Fmt.usd(priced.cost.total))
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }
        }
    }
}

/// "What is Claude doing right now": live state plus the latest steps, linking to the full trace.
struct LiveActivityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let sessionID = model.traceSessions.first?.id {
            let trace = model.trace(for: sessionID)
            let usage = model.usageByMessage(sessionID: sessionID)
            VStack(alignment: .leading, spacing: 10) {
                TraceStatusBanner(trace: trace, usage: usage)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(trace.items.filter { $0.kind != .context && $0.kind != .toolResult }.suffix(6).reversed())) { item in
                        HStack(spacing: 8) {
                            Text(item.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 66, alignment: .leading)
                            Image(systemName: TraceStyle.icon(for: item.kind))
                                .foregroundStyle(item.isError ? Palette.critical : TraceStyle.color(for: item.kind))
                                .frame(width: 16)
                            Text(item.title).lineLimit(1)
                            if let tool = trace.tools.first(where: { $0.call.id == item.id }) {
                                ToolStatusChip(tool: tool)
                            }
                            Spacer()
                        }
                        .font(.callout)
                    }
                }
                HStack {
                    Button {
                        model.selection = .trace
                    } label: {
                        Label("Открыть Live-трассу", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    Text("промпты, размышления, инструменты, MCP, скиллы, контекст и поток — подробно и в реальном времени")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
