import SwiftUI
import XRayCore

enum TraceTab: String, CaseIterable, Identifiable {
    case feed, flow, llm, timeline, context, tools

    var id: Self { self }

    var title: String {
        switch self {
        case .feed: return "Лента"
        case .flow: return "Поток"
        case .llm: return "LLM-запросы"
        case .timeline: return "Таймлайн"
        case .context: return "Контекст"
        case .tools: return "Инструменты · MCP · скиллы"
        }
    }
}

/// Live trace: what Claude Code is doing right now and every step it took, in full detail.
struct TraceView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("trace.hideContent") private var hideContent = false

    var body: some View {
        @Bindable var model = model
        let sessions = model.traceSessions

        VStack(alignment: .leading, spacing: 0) {
            if let sessionID = model.traceSessionID {
                let trace = model.trace(for: sessionID)
                let usage = model.usageByMessage(sessionID: sessionID)

                TraceHeader(sessions: sessions, trace: trace, hideContent: $hideContent)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                TraceStatusBanner(trace: trace, usage: usage)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)

                Picker("Раздел", selection: $model.traceTab) {
                    ForEach(TraceTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                Divider()

                Group {
                    switch model.traceTab {
                    case .feed: TraceFeedView(trace: trace, usage: usage, hideContent: hideContent)
                    case .flow: TraceFlowView(trace: trace, usage: usage, hideContent: hideContent)
                    case .llm: TraceLLMView(trace: trace, usage: usage, hideContent: hideContent)
                    case .timeline: TraceTimelineView(trace: trace, usage: usage)
                    case .context: TraceContextView(trace: trace, usage: usage)
                    case .tools: TraceToolsView(trace: trace)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                SourcesHelpView(
                    title: "Нет активности за последние 3 дня",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    message: "Как только Claude Code начнёт работать на этом Mac, здесь в реальном времени появятся промпты, размышления, вызовы инструментов, MCP, скиллы, субагенты и контекст."
                )
            }
        }
    }
}

/// Session picker, privacy switch and session facts.
struct TraceHeader: View {
    @Environment(AppModel.self) private var model
    let sessions: [SessionActivity]
    let trace: SessionTrace
    @Binding var hideContent: Bool

    var body: some View {
        HStack(spacing: 14) {
            Picker("Сессия", selection: Binding(
                get: { model.pinnedTraceSession ?? "" },
                set: { model.pinnedTraceSession = $0.isEmpty ? nil : $0 }
            )) {
                Text("Следовать за активной сессией").tag("")
                Divider()
                ForEach(sessions) { session in
                    Text("\(session.projectName) · \(session.gitBranch ?? "—") · \(Fmt.dateTime(session.lastActivity)) · \(Fmt.plural(session.items, "событие", "события", "событий"))")
                        .tag(session.id)
                }
            }
            .frame(maxWidth: 520)

            Toggle("Скрыть содержимое", isOn: $hideContent)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Скрывает тексты промптов, ответов, команд и выводов — удобно для демонстрации экрана")

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(trace.projectPath ?? "—").font(.caption).textSelection(.enabled)
                Text("сессия \(trace.sessionID.prefix(8)) · \(Fmt.plural(trace.items.count, "событие", "события", "событий")) · ошибок: \(trace.errors)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Big live status: state, what exactly runs, for how long, and session totals. Ticks every second.
struct TraceStatusBanner: View {
    let trace: SessionTrace
    let usage: [String: PricedEvent]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            let state = trace.status?.state ?? .idle
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: TraceStyle.icon(for: state))
                    .font(.system(size: 30))
                    .foregroundStyle(TraceStyle.color(for: state))
                    .symbolEffect(.pulse, isActive: state.isActive)
                    .frame(width: 46)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(state.title).font(.title2.weight(.semibold))
                        if let status = trace.status {
                            Text(Fmt.shortDuration(status.elapsed(at: now)))
                                .font(.title3.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let detail = state.detail {
                        Text(detail)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if let status = trace.status {
                        Text(turnLine(status, now: now))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 20)

                SessionTotalsView(usage: usage)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(TraceStyle.color(for: state).opacity(0.5), lineWidth: 1.5))
        }
    }

    private func turnLine(_ status: LiveStatus, now: Date) -> String {
        var parts: [String] = []
        if let start = status.turnStart {
            parts.append("ход идёт \(Fmt.shortDuration(now.timeIntervalSince(start)))")
        }
        parts.append("ответов модели: \(status.stepsInTurn)")
        parts.append("вызовов инструментов: \(status.toolsInTurn)")
        if status.runningTools > 1 {
            parts.append("параллельно: \(status.runningTools)")
        }
        parts.append("последнее событие \(Fmt.shortDuration(now.timeIntervalSince(status.lastActivity))) назад")
        return parts.joined(separator: " · ")
    }
}

/// Session cost, tokens, current context and cache, from the priced usage.
struct SessionTotalsView: View {
    let usage: [String: PricedEvent]

    var body: some View {
        let events = usage.values.sorted { $0.event.timestamp < $1.event.timestamp }
        let summary = UsageSummary.of(events)
        let last = events.last { !$0.event.isSidechain } ?? events.last
        let context = last?.event.tokens.contextTokens ?? 0
        let window = last.map { ModelCatalog.contextWindow(for: $0.event.model) } ?? 1_000_000

        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                Text("Сессия").foregroundStyle(.secondary)
                Text(Fmt.usd(summary.cost.total)).monospacedDigit()
            }
            GridRow {
                Text("Токены").foregroundStyle(.secondary)
                Text("\(Fmt.tokens(summary.tokens.total)) · \(Fmt.plural(summary.requests, "запрос", "запроса", "запросов"))").monospacedDigit()
            }
            GridRow {
                Text("Контекст").foregroundStyle(.secondary)
                Text("\(Fmt.tokens(context)) из \(Fmt.tokens(window)) · \(Fmt.percent(Double(context) / Double(max(window, 1))))").monospacedDigit()
            }
            GridRow {
                Text("Кэш, последний запрос").foregroundStyle(.secondary)
                Text(last.map { Fmt.percent($0.event.tokens.cacheHitRate) } ?? "—").monospacedDigit()
            }
        }
        .font(.callout)
    }
}
