import Charts
import SwiftUI
import XRayCore

/// Turn-by-turn flow: prompt → model responses → tool calls → results → answer, plus a transition map.
struct TraceFlowView: View {
    let trace: SessionTrace
    let usage: [String: PricedEvent]
    let hideContent: Bool
    /// Turns whose expansion differs from the default (latest expanded, others collapsed).
    @State private var toggled: Set<String> = []

    var body: some View {
        let latestID = trace.turns.last?.id

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CardRow {
                    Card(title: L("Карта переходов"), subtitle: L("что за чем следует в основном потоке")) {
                        TransitionsChart(transitions: Array(trace.transitions.prefix(16)))
                    }
                    Card(title: L("Ходы сессии")) {
                        TurnSummaryGrid(trace: trace, usage: usage)
                    }
                    .frame(maxWidth: 380)
                }

                ForEach(trace.turns.reversed()) { turn in
                    let expanded = (turn.id == latestID) != toggled.contains(turn.id)
                    TurnCard(turn: turn, usage: usage, hideContent: hideContent, expanded: expanded) {
                        if toggled.contains(turn.id) { toggled.remove(turn.id) } else { toggled.insert(turn.id) }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct TransitionsChart: View {
    let transitions: [FlowTransition]

    var body: some View {
        if transitions.isEmpty {
            Text(L("Переходов пока нет")).foregroundStyle(.secondary)
        } else {
            RankedBarList(rows: transitions.map { transition in
                RankedBarRow(id: transition.id, label: transition.id, value: Double(transition.count), valueText: Fmt.plural(transition.count, "раз", "раза", "раз"))
            })
        }
    }
}

/// Totals over all turns.
struct TurnSummaryGrid: View {
    let trace: SessionTrace
    let usage: [String: PricedEvent]

    var body: some View {
        let outcomes = Dictionary(grouping: trace.turns, by: \.outcome).mapValues(\.count)
        let mainSteps = trace.steps.filter { !$0.isSidechain }
        let thinking = trace.steps.reduce(0) { $0 + $1.thinkingMs }
        let streaming = trace.steps.reduce(0) { $0 + $1.inputStreamMs }

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row(L("Ходов"), "\(trace.turns.filter { $0.prompt != nil }.count)")
            row(L("Завершено / прервано"), "\(outcomes[.completed] ?? 0) / \(outcomes[.interrupted] ?? 0)")
            row(L("Ответов модели"), L("\(mainSteps.count) + \(trace.steps.count - mainSteps.count) у субагентов"))
            row(L("Вызовов инструментов"), L("\(trace.tools.count), ошибок \(trace.tools.filter(\.isError).count)"))
            row(L("Время размышлений"), Fmt.ms(thinking))
            row(L("Генерация ввода инструментов"), Fmt.ms(streaming))
            row(L("Сообщений во время работы"), "\(trace.items.filter { $0.kind == .queued && $0.title.hasPrefix(L("В очереди")) }.count)")
            row(L("API-эквивалент"), Fmt.usd(usage.values.reduce(0) { $0 + $1.cost.total }))
        }
        .font(.callout)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// One turn: header with totals and, when expanded, the full tree.
struct TurnCard: View {
    let turn: TraceTurn
    let usage: [String: PricedEvent]
    let hideContent: Bool
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let cost = turn.stepIDs.compactMap { usage[$0]?.cost.total }.reduce(0, +)
        let tokens = turn.stepIDs.compactMap { usage[$0]?.event.tokens.total }.reduce(0, +)

        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                    Text(turn.prompt == nil ? L("Начало сессии") : L("Ход \(turn.index)")).font(.headline)
                    Chip(text: TraceStyle.title(for: turn.outcome), tint: TraceStyle.color(for: turn.outcome))
                    if let prompt = turn.prompt {
                        Text(TraceText.title(for: prompt, hideContent: hideContent)).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text(L("\(Fmt.dateTime(turn.start)) · \(Fmt.shortDuration(turn.duration)) · \(turn.stepIDs.count) отв. · \(turn.toolCalls) инстр. · \(Fmt.tokens(tokens)) ток. · \(Fmt.usd(cost))"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if turn.errors > 0 {
                        Chip(text: L("ошибок \(turn.errors)"), systemImage: "xmark.circle.fill", tint: Palette.critical)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if let prompt = turn.prompt {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: TraceStyle.icon(for: .prompt)).foregroundStyle(TraceStyle.color(for: .prompt))
                        if hideContent {
                            Text(TraceText.title(for: prompt, hideContent: true))
                        } else {
                            DetailBlock(text: prompt.detail ?? prompt.title)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(turn.nodes) { node in
                        FlowNodeView(node: node, usage: usage, hideContent: hideContent)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }
}

struct FlowNodeView: View {
    let node: FlowNode
    let usage: [String: PricedEvent]
    let hideContent: Bool

    var body: some View {
        switch node {
        case let .step(step, children):
            FlowStepView(step: step, children: children, usage: usage[step.messageID], hideContent: hideContent)
        case let .tool(tool):
            FlowToolRow(tool: tool, hideContent: hideContent)
        case let .item(item):
            FlowItemRow(item: item, hideContent: hideContent)
        }
    }
}

/// A model response with its blocks and tool calls, joined by a connector line.
struct FlowStepView: View {
    let step: ModelStep
    let children: [FlowNode]
    let usage: PricedEvent?
    let hideContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "brain").foregroundStyle(Palette.model)
                Text(step.model.map(ModelCatalog.displayName(for:)) ?? L("Модель")).font(.callout.weight(.semibold))
                if step.isSidechain { Chip(text: L("субагент"), systemImage: "person.2", tint: Palette.subagent) }
                if let effort = step.effort { Chip(text: "effort \(effort)", tint: Palette.other) }
                Chip(text: L("шаг \(Fmt.shortDuration(step.duration))"), systemImage: "timer", tint: Palette.other)
                if step.thinkingMs > 0 { Chip(text: L("думал \(Fmt.ms(step.thinkingMs))"), systemImage: "brain", tint: Palette.model) }
                if step.inputStreamMs > 0 { Chip(text: L("ввод \(Fmt.ms(step.inputStreamMs))"), systemImage: "keyboard", tint: Palette.other) }
                if let skill = step.attributionSkill { Chip(text: L("скилл \(skill)"), systemImage: "sparkles", tint: Palette.skill) }
                Spacer()
                Text(step.start.localized(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let usage {
                UsageLine(priced: usage)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(children) { child in
                    switch child {
                    case let .tool(tool): FlowToolRow(tool: tool, hideContent: hideContent)
                    case let .item(item): FlowItemRow(item: item, hideContent: hideContent)
                    case .step: EmptyView()
                    }
                }
            }
            .padding(.leading, 22)
            .overlay(alignment: .leading) {
                Rectangle().fill(Palette.hairline).frame(width: 2).padding(.leading, 7)
            }
        }
    }
}

struct FlowToolRow: View {
    let tool: ToolExecution
    let hideContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: TraceStyle.icon(for: tool.category))
                    .foregroundStyle(tool.isError ? Palette.critical : TraceStyle.color(for: .toolCall))
                    .frame(width: 16)
                Text(TraceText.title(for: tool.call, hideContent: hideContent))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                ToolStatusChip(tool: tool)
            }
            if let result = tool.result, !hideContent {
                Text("↳ " + result.title)
                    .font(.caption)
                    .foregroundStyle(result.isError ? Palette.critical : .secondary)
                    .lineLimit(1)
                    .padding(.leading, 22)
            }
        }
    }
}

struct FlowItemRow: View {
    let item: ActivityItem
    let hideContent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: TraceStyle.icon(for: item.kind))
                .foregroundStyle(item.isError ? Palette.critical : TraceStyle.color(for: item.kind))
                .frame(width: 16)
            Text(TraceText.title(for: item, hideContent: hideContent))
                .font(.callout)
                .foregroundStyle(item.kind == .context || item.kind == .note ? Color.secondary : Color.primary)
                .lineLimit(2)
            if let ms = item.thinkingMs, ms > 0 {
                Chip(text: Fmt.ms(ms), systemImage: "brain", tint: Palette.model)
            }
            Spacer(minLength: 8)
            Text(item.timestamp.localized(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
