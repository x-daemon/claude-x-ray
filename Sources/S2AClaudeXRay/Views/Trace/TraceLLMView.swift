import SwiftUI
import XRayCore

/// Colors of token segments, in the cost-component colors: input, output, cache read, cache write; thinking.
enum TokenSegment {
    static var input: Color { Palette.series[0] }
    static var output: Color { Palette.series[1] }
    static var read: Color { Palette.series[2] }
    static var write: Color { Palette.series[3] }
    static var thinking: Color { Palette.series[5] }
}

extension LLMCalls.Tone {
    var color: Color {
        switch self {
        case .good: return Palette.good
        case .info: return Palette.tool
        case .warning: return Palette.warning
        case .critical: return Palette.critical
        case .neutral: return Palette.other
        }
    }
}

/// "LLM-запросы": every request to the model with its API-level details, and the agent loop
/// (thought → action → result) of each turn.
struct TraceLLMView: View {
    let trace: SessionTrace
    let usage: [String: PricedEvent]
    let hideContent: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case calls, loop
        var id: Self { self }
        var title: String { self == .calls ? "Запросы" : "Цикл агента" }
    }

    @State private var mode: Mode = .calls

    var body: some View {
        let calls = LLMCalls.build(trace: trace, usage: usage)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CallTiles(calls: calls)
                HStack(spacing: 12) {
                    Picker("Вид", selection: $mode) {
                        ForEach(Mode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    Text(mode == .calls ? "каждый вызов модели: токены, кэш, причина остановки, размышления и действия" : "мысль → действие → результат для каждого запроса хода")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if calls.isEmpty {
                    Text("Запросов к модели в этой сессии пока нет").foregroundStyle(.secondary).frame(height: 80)
                } else if mode == .calls {
                    CallList(calls: calls, hideContent: hideContent)
                } else {
                    AgentLoopView(trace: trace, calls: calls, hideContent: hideContent)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Tiles

private struct CallTiles: View {
    @Environment(AppModel.self) private var model
    let calls: [LLMCall]

    var body: some View {
        let stats = Stats(calls: calls, pricing: model.pricing)
        HStack(spacing: 12) {
            StatTile(
                title: "Запросов к модели", value: "\(calls.count)",
                caption: "основной поток \(stats.main) · субагенты \(calls.count - stats.main)", systemImage: "brain"
            )
            StatTile(
                title: "Чтение из кэша", value: stats.context > 0 ? Fmt.percent(Double(stats.read) / Double(stats.context)) : "—",
                caption: "доля контекста всех запросов", systemImage: "memorychip"
            )
            StatTile(
                title: "Промахи кэша", value: "\(stats.misses)",
                caption: stats.misses > 0 ? "≈\(Fmt.usd(stats.extra)) лишней записи" : "с понятной причиной — нет",
                systemImage: "exclamationmark.triangle"
            )
            StatTile(
                title: "Потеряно размышлений", value: "\(stats.dropped)",
                caption: stats.dropped > 0 ? "блоков в \(Fmt.plural(stats.droppedCalls, "запросе", "запросах", "запросах"))" : "API ничего не отбрасывало",
                systemImage: "brain.head.profile"
            )
            StatTile(
                title: "Чем заканчивались ответы", value: stats.topStopShare,
                caption: stats.stopCaption, systemImage: "stop.circle"
            )
        }
    }

    private struct Stats {
        var main = 0
        var read = 0
        var context = 0
        var misses = 0
        var extra = 0.0
        var dropped = 0
        var droppedCalls = 0
        var topStopShare = "—"
        var stopCaption: String?

        init(calls: [LLMCall], pricing: PricingTable) {
            var stops: [String: Int] = [:]
            for call in calls {
                if !call.step.isSidechain { main += 1 }
                if let priced = call.priced {
                    read += priced.event.tokens.cacheRead
                    context += priced.event.tokens.contextTokens
                }
                let details = call.details
                if let miss = details.cacheMiss, LLMCalls.isRealMiss(miss.reason), let priced = call.priced {
                    misses += 1
                    extra += RequestIssues.missExtraCost(pricing: pricing, priced: priced, tokens: miss.missedTokens ?? priced.event.tokens.cacheWrite)
                }
                let lost = details.droppedThinking
                dropped += lost
                if lost > 0 { droppedCalls += 1 }
                if let stop = details.stopReason ?? call.step.stopReason { stops[stop, default: 0] += 1 }
            }
            if let top = stops.max(by: { $0.value < $1.value }) {
                topStopShare = Fmt.percent(Double(top.value) / Double(max(calls.count, 1)))
                let others = stops.filter { $0.key != top.key }
                    .sorted { $0.value > $1.value }
                    .map { "\(LLMCalls.stopReason($0.key).title) \($0.value)" }
                stopCaption = ([LLMCalls.stopReason(top.key).title] + others).joined(separator: " · ")
            }
        }
    }
}

// MARK: - Calls

private struct CallList: View {
    let calls: [LLMCall]
    let hideContent: Bool
    @State private var onlyIssues = false
    @State private var limit = 40
    @State private var toggled: Set<Int> = []

    var body: some View {
        let latest = calls.last?.index
        let shown = calls.reversed().filter { !onlyIssues || $0.hasIssue }
        let maxContext = max(calls.map(\.contextTokens).max() ?? 1, 1)
        let maxOutput = max(calls.map { $0.priced?.event.tokens.output ?? 0 }.max() ?? 1, 1)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Toggle("Только с проблемами", isOn: $onlyIssues)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("промахи кэша, потерянные размышления, отказы, обрезанные ответы, ошибки инструментов")
                Text(Fmt.plural(shown.count, "запрос", "запроса", "запросов")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                SegmentLegend()
            }
            ForEach(Array(shown.prefix(limit))) { call in
                CallCard(
                    call: call,
                    hideContent: hideContent,
                    expanded: (call.index == latest) != toggled.contains(call.index),
                    maxContext: maxContext,
                    maxOutput: maxOutput
                ) {
                    if toggled.contains(call.index) { toggled.remove(call.index) } else { toggled.insert(call.index) }
                }
            }
            if shown.count > limit {
                Button("Показать ещё \(min(40, shown.count - limit))") { limit += 40 }
                    .frame(maxWidth: .infinity)
            }
            if shown.isEmpty {
                Text("Запросов с проблемами нет").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            }
        }
    }
}

struct SegmentLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            Label("чтение кэша", systemImage: "square.fill").foregroundStyle(TokenSegment.read)
            Label("запись в кэш", systemImage: "square.fill").foregroundStyle(TokenSegment.write)
            Label("свежий ввод", systemImage: "square.fill").foregroundStyle(TokenSegment.input)
            Label("размышления", systemImage: "square.fill").foregroundStyle(TokenSegment.thinking)
            Label("вывод", systemImage: "square.fill").foregroundStyle(TokenSegment.output)
        }
        .font(.caption)
        .labelStyle(LegendLabelStyle())
    }
}

private struct CallCard: View {
    let call: LLMCall
    let hideContent: Bool
    let expanded: Bool
    let maxContext: Int
    let maxOutput: Int
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                CallHeader(call: call, expanded: expanded).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if call.priced != nil {
                TokenBars(call: call, maxContext: maxContext, maxOutput: maxOutput)
            } else {
                Text("Токены этого ответа в логе не найдены").font(.caption).foregroundStyle(.secondary)
            }
            CallNotes(call: call)
            if expanded {
                Divider()
                CallBody(call: call, hideContent: hideContent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
        .overlay(alignment: .leading) {
            if call.hasIssue {
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(Palette.warning).frame(width: 3)
            }
        }
    }
}

private struct CallHeader: View {
    let call: LLMCall
    let expanded: Bool

    var body: some View {
        let details = call.details
        let stop = LLMCalls.stopReason(details.stopReason ?? call.step.stopReason, category: details.stopCategory)
        let model = call.step.model ?? call.priced?.event.model
        let requested = call.step.requestedModel ?? details.requestedModel
        let effort = call.step.effort ?? call.priced?.event.effort
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
            Text("#\(call.index)").font(.callout.weight(.semibold)).monospacedDigit()
            Text(call.step.start.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let model { Chip(text: ModelCatalog.displayName(for: model), systemImage: "cpu", tint: Palette.model) }
                if call.modelSwitched, let requested {
                    Chip(text: "запрошена \(ModelCatalog.displayName(for: requested))", systemImage: "arrow.triangle.swap", tint: Palette.warning)
                }
                if let effort { Chip(text: "effort \(effort)", systemImage: "dial.medium", tint: Palette.other) }
            }
            HStack(spacing: 6) {
                if call.priced?.event.isFastMode == true { Chip(text: "fast", systemImage: "bolt", tint: Palette.warning) }
                if call.step.isSidechain { Chip(text: "субагент", systemImage: "person.2", tint: Palette.subagent) }
                if let advisor = details.advisorModel {
                    Chip(text: "советник \(ModelCatalog.displayName(for: advisor))", systemImage: "lightbulb", tint: Palette.other)
                }
                Chip(text: stop.title, tint: stop.tone.color)
            }
            Spacer(minLength: 8)
            Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var summary: String {
        var parts = [Fmt.shortDuration(call.step.duration)]
        if let tokens = call.priced?.event.tokens {
            parts.append("\(Fmt.tokens(tokens.contextTokens)) → \(Fmt.tokens(tokens.output))")
            parts.append(Fmt.usd(call.cost))
        }
        return parts.joined(separator: " · ")
    }
}

/// Input composition (scaled to the session's largest prompt) and output split.
private struct TokenBars: View {
    let call: LLMCall
    let maxContext: Int
    let maxOutput: Int

    var body: some View {
        let tokens = call.priced?.event.tokens ?? TokenCounts()
        let window = ModelCatalog.contextWindow(for: call.priced?.event.model ?? "")
        let visible = max(0, tokens.output - tokens.thinking)
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("вход").font(.caption).foregroundStyle(.secondary)
                SegmentBar(
                    parts: [(tokens.cacheRead, TokenSegment.read), (tokens.cacheWrite, TokenSegment.write), (tokens.input, TokenSegment.input)],
                    fraction: Double(tokens.contextTokens) / Double(maxContext)
                )
                Text(inputText(tokens, window: window)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            GridRow {
                Text("выход").font(.caption).foregroundStyle(.secondary)
                SegmentBar(
                    parts: [(tokens.thinking, TokenSegment.thinking), (visible, TokenSegment.output)],
                    fraction: Double(tokens.output) / Double(maxOutput)
                )
                Text(tokens.thinking > 0 ? "\(Fmt.tokens(tokens.output)) · размышления \(Fmt.tokens(tokens.thinking))" : Fmt.tokens(tokens.output))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func inputText(_ tokens: TokenCounts, window: Int) -> String {
        var text = "\(Fmt.tokens(tokens.contextTokens)) · \(Fmt.percent(Double(tokens.contextTokens) / Double(max(window, 1)))) окна · из кэша \(Fmt.percent(tokens.cacheHitRate))"
        if tokens.cacheWrite > 0 {
            text += " · запись \(Fmt.tokens(tokens.cacheWrite))" + (tokens.cacheWrite1h > 0 ? " (1 ч)" : " (5 мин)")
        }
        return text
    }
}

/// Proportional segments with 1 pt gaps, drawn to `fraction` of the available width.
struct SegmentBar: View {
    let parts: [(Int, Color)]
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            let total = max(parts.reduce(0) { $0 + $1.0 }, 1)
            let width = max(3, proxy.size.width * min(max(fraction, 0), 1))
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if part.0 > 0 {
                        Rectangle()
                            .fill(part.1)
                            .frame(width: max(1, width * CGFloat(part.0) / CGFloat(total)))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(height: 10)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 12)
    }
}

/// Cache miss, dropped thinking, context edits, iterations, model switch: one line each.
private struct CallNotes: View {
    @Environment(AppModel.self) private var model
    let call: LLMCall

    private struct Note: Identifiable {
        let id = UUID()
        let icon: String
        let color: Color
        let text: String
    }

    var body: some View {
        let notes = makeNotes()
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(notes) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: note.icon).foregroundStyle(note.color).frame(width: 14)
                        Text(note.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func makeNotes() -> [Note] {
        let details = call.details
        var notes: [Note] = []
        if let miss = details.cacheMiss {
            let tokens = miss.missedTokens ?? call.priced?.event.tokens.cacheWrite ?? 0
            if LLMCalls.isRealMiss(miss.reason) {
                let extra = call.priced.map { RequestIssues.missExtraCost(pricing: model.pricing, priced: $0, tokens: tokens) } ?? 0
                let cost = extra > 0 ? " (≈\(Fmt.usd(extra)))" : ""
                notes.append(Note(icon: "exclamationmark.triangle.fill", color: Palette.warning,
                                  text: "Промах кэша: \(LLMCalls.cacheMissTitle(miss.reason)) — \(Fmt.tokens(tokens)) токенов записаны заново\(cost)"))
            } else {
                notes.append(Note(icon: "info.circle", color: Palette.other, text: "Кэш: \(LLMCalls.cacheMissTitle(miss.reason))"))
            }
        }
        for transformation in details.transformations {
            if transformation.type == "thinking_dropped" {
                let path = transformation.path.map { " (\($0))" } ?? ""
                notes.append(Note(icon: "brain", color: Palette.warning,
                                  text: "API убрало размышление из истории: \(LLMCalls.droppedReasonTitle(transformation.reason))\(path)"))
            } else {
                notes.append(Note(icon: "info.circle", color: Palette.other, text: "Изменение запроса API: \(transformation.type)"))
            }
        }
        for edit in details.contextEdits {
            var parts: [String] = []
            if let tokens = edit.clearedTokens { parts.append("\(Fmt.tokens(tokens)) токенов") }
            if let uses = edit.clearedToolUses { parts.append("\(uses) вызовов") }
            let suffix = parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")
            notes.append(Note(icon: "arrow.down.right.and.arrow.up.left", color: Palette.context, text: "Сервер очистил контекст (\(edit.type))\(suffix)"))
        }
        if !details.iterations.isEmpty {
            let steps = details.iterations.map { step -> String in
                let model = step.model.map { " (\(ModelCatalog.displayName(for: $0)))" } ?? ""
                return "\(LLMCalls.iterationTitle(step.type))\(model): вывод \(Fmt.tokens(step.output))"
            }
            notes.append(Note(icon: "square.stack.3d.up", color: Palette.other, text: "Шаги запроса: " + steps.joined(separator: " → ")))
        }
        if call.modelSwitched {
            let requested = ModelCatalog.displayName(for: call.step.requestedModel ?? details.requestedModel ?? "")
            let served = ModelCatalog.displayName(for: call.step.model ?? call.priced?.event.model ?? "")
            notes.append(Note(icon: "arrow.triangle.swap", color: Palette.warning, text: "Запрошена \(requested), ответила \(served)"))
        }
        return notes
    }
}

private struct CallBody: View {
    let call: LLMCall
    let hideContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Размышления").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if call.thinking.isEmpty {
                    Text("Без блока размышлений").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(call.thinking) { item in
                    ThinkingBlock(item: item, thinkingTokens: call.priced?.event.tokens.thinking ?? 0, hideContent: hideContent)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Действия (\(call.tools.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if call.tools.isEmpty {
                    Text("Инструменты не вызывались").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(call.tools) { tool in
                    ActionView(tool: tool, hideContent: hideContent)
                }
            }
            if !call.replies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ответ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(call.replies) { reply in
                        if hideContent {
                            Text(TraceText.title(for: reply, hideContent: true)).font(.caption).foregroundStyle(.secondary)
                        } else {
                            DetailBlock(text: reply.detail ?? reply.title)
                        }
                    }
                }
            }
            Text(meta)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var meta: String {
        let details = call.details
        let event = call.priced?.event
        var parts: [String] = [call.step.messageID]
        if let request = event?.requestID { parts.append(request) }
        if let tier = event?.serviceTier { parts.append("tier \(tier)") }
        if let geo = details.inferenceGeo { parts.append("регион \(geo)") }
        if let speed = event?.speed { parts.append("скорость \(speed)") }
        if let ttl = details.cacheTTL { parts.append("TTL кэша \(ttl)") }
        if let searches = event?.webSearchRequests, searches > 0 { parts.append("веб-поиск \(searches)") }
        return parts.joined(separator: " · ")
    }
}

private struct ThinkingBlock: View {
    let item: ActivityItem
    let thinkingTokens: Int
    let hideContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "brain").foregroundStyle(Palette.model)
                Text(item.thinkingMs.map { "думал \(Fmt.ms($0))" } ?? "размышление")
                Text("· режим API: \(LLMCalls.thinkingDisplayTitle(item.thinkingDisplay))").foregroundStyle(.secondary)
            }
            .font(.caption)
            if let text = item.detail, !hideContent {
                DetailBlock(text: text)
            } else {
                Text(hideContent
                     ? "Скрыто переключателем «Скрыть содержимое»."
                     : "Текст размышлений API не возвращает — известны только длительность и \(Fmt.tokens(thinkingTokens)) токенов размышлений.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ActionView: View {
    let tool: ToolExecution
    let hideContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            Text(metaLine).font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            if !hideContent, let raw = tool.call.rawInput, !raw.isEmpty {
                Text("Аргументы, которые сгенерировала модель").font(.caption2).foregroundStyle(.secondary)
                DetailBlock(text: raw)
            }
            if !hideContent, let executed = tool.call.execInput {
                Text("Claude Code выполнил с изменёнными аргументами").font(.caption2).foregroundStyle(Palette.warning)
                DetailBlock(text: executed)
            }
            if let result = tool.result, !hideContent {
                Text("↳ " + result.title)
                    .font(.caption)
                    .foregroundStyle(result.isError ? Palette.critical : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.emptyCell.opacity(0.55)))
    }

    private var metaLine: String {
        var parts: [String] = []
        if let ms = tool.call.inputStreamMs, ms > 0 { parts.append("аргументы генерировались \(Fmt.ms(ms))") }
        if let result = tool.result {
            if let decision = LLMCalls.decisionTitle(result) { parts.append(decision) }
            if result.sandboxed == true { parts.append("в песочнице") }
            parts.append("результат \(Fmt.bytes(result.outputBytes ?? 0)) за \(Fmt.shortDuration(tool.duration(now: Date())))")
        } else {
            parts.append("выполняется")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Agent loop

private struct AgentLoopView: View {
    let trace: SessionTrace
    let calls: [LLMCall]
    let hideContent: Bool
    @State private var selected: Int?

    var body: some View {
        let turnIndices = Set(calls.map(\.turn))
        let turns = trace.turns.enumerated().filter { turnIndices.contains($0.offset) }
        let current = selected ?? turns.last?.offset ?? 0
        let turn = current < trace.turns.count ? trace.turns[current] : nil
        let turnCalls = calls.filter { $0.turn == current }

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Ход", selection: Binding(get: { current }, set: { selected = $0 })) {
                    ForEach(turns, id: \.offset) { position, item in
                        Text(turnTitle(item, count: calls.filter { $0.turn == position }.count)).tag(position)
                    }
                }
                .frame(maxWidth: 560)
                Text(totals(turnCalls, turn: turn)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            if let prompt = turn?.prompt {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: TraceStyle.icon(for: .prompt)).foregroundStyle(TraceStyle.color(for: .prompt))
                    Text(hideContent ? TraceText.title(for: prompt, hideContent: true) : (prompt.detail ?? prompt.title))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.user.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
            }
            Grid(alignment: .topLeading, horizontalSpacing: 6, verticalSpacing: 8) {
                GridRow {
                    Text("Мысль").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Color.clear.frame(width: 14, height: 1)
                    Text("Действие").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Color.clear.frame(width: 14, height: 1)
                    Text("Результат").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(turnCalls) { call in
                    GridRow {
                        ThoughtCell(call: call, hideContent: hideContent)
                        Arrow()
                        ActionCell(call: call, hideContent: hideContent)
                        Arrow()
                        ResultCell(call: call, hideContent: hideContent)
                    }
                }
            }
        }
    }

    private func turnTitle(_ turn: TraceTurn, count: Int) -> String {
        let head = turn.prompt == nil ? "Начало сессии" : "Ход \(turn.index)"
        let prompt = turn.prompt.map { Snippet.truncate(TraceText.title(for: $0, hideContent: hideContent), 60) } ?? "без промпта"
        return "\(head) · \(prompt) · \(Fmt.plural(count, "запрос", "запроса", "запросов"))"
    }

    private func totals(_ calls: [LLMCall], turn: TraceTurn?) -> String {
        let tools = calls.reduce(0) { $0 + $1.tools.count }
        let cost = calls.reduce(0) { $0 + $1.cost }
        var parts = [Fmt.plural(calls.count, "запрос", "запроса", "запросов"), Fmt.plural(tools, "действие", "действия", "действий"), Fmt.usd(cost)]
        if let turn { parts.append(Fmt.shortDuration(turn.duration)) }
        return parts.joined(separator: " · ")
    }
}

private struct Arrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(width: 14)
            .frame(maxHeight: .infinity)
    }
}

private struct LoopCell<Content: View>: View {
    var dashed = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) { content }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
            )
    }
}

private struct ThoughtCell: View {
    let call: LLMCall
    let hideContent: Bool

    var body: some View {
        let details = call.details
        let tokens = call.priced?.event.tokens
        let thinkingMs = call.thinking.reduce(0) { $0 + ($1.thinkingMs ?? 0) }
        let note = call.thinking.first { $0.detail != nil }?.detail
        LoopCell(dashed: call.step.isSidechain) {
            HStack(spacing: 6) {
                Text("#\(call.index)").font(.caption.weight(.semibold)).monospacedDigit()
                Chip(text: ModelCatalog.displayName(for: call.step.model ?? call.priced?.event.model ?? "модель"), systemImage: "cpu", tint: Palette.model)
                if call.step.isSidechain { Chip(text: "субагент", systemImage: "person.2", tint: Palette.subagent) }
                if let miss = details.cacheMiss, LLMCalls.isRealMiss(miss.reason) {
                    Chip(text: "промах кэша", systemImage: "exclamationmark.triangle.fill", tint: Palette.warning)
                        .help(LLMCalls.cacheMissTitle(miss.reason))
                }
                if details.droppedThinking > 0 { Chip(text: "размышление потеряно", systemImage: "brain", tint: Palette.warning) }
            }
            Text(summary(thinkingMs: thinkingMs, tokens: tokens)).font(.caption).foregroundStyle(.secondary)
            if let note, !hideContent {
                Text("«\(note)»").font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.leading, call.step.isSidechain ? 18 : 0)
    }

    private func summary(thinkingMs: Int, tokens: TokenCounts?) -> String {
        var text = thinkingMs > 0 ? "думал \(Fmt.ms(thinkingMs))" : "без размышлений"
        if let tokens {
            text += " · вход \(Fmt.tokens(tokens.contextTokens)) · вывод \(Fmt.tokens(tokens.output))"
            if tokens.thinking > 0 { text += " (размышления \(Fmt.tokens(tokens.thinking)))" }
        }
        return text
    }
}

private struct ActionCell: View {
    let call: LLMCall
    let hideContent: Bool

    var body: some View {
        let stop = LLMCalls.stopReason(call.details.stopReason ?? call.step.stopReason, category: call.details.stopCategory)
        LoopCell {
            if !call.tools.isEmpty {
                ForEach(call.tools) { tool in
                    HStack(spacing: 6) {
                        Image(systemName: TraceStyle.icon(for: tool.category)).foregroundStyle(TraceStyle.color(for: .toolCall)).frame(width: 14)
                        Text(TraceText.title(for: tool.call, hideContent: hideContent))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            } else if let reply = call.replies.first {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: TraceStyle.icon(for: .reply)).foregroundStyle(TraceStyle.color(for: .reply)).frame(width: 14)
                    Text(hideContent ? "Ответ" : reply.title).font(.caption).lineLimit(2)
                }
            } else {
                Text("—").font(.caption).foregroundStyle(.secondary)
            }
            if stop.tone == .warning || stop.tone == .critical {
                Chip(text: stop.title, tint: stop.tone.color)
            }
        }
    }
}

private struct ResultCell: View {
    let call: LLMCall
    let hideContent: Bool

    var body: some View {
        let stop = LLMCalls.stopReason(call.details.stopReason ?? call.step.stopReason, category: call.details.stopCategory)
        LoopCell {
            if !call.tools.isEmpty {
                ForEach(call.tools) { tool in
                    HStack(spacing: 6) {
                        ToolStatusChip(tool: tool)
                        Text(resultText(tool))
                            .font(.caption)
                            .foregroundStyle(tool.isError ? Palette.critical : .secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(stop.tone == .good ? "ход завершён" : stop.title).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func resultText(_ tool: ToolExecution) -> String {
        guard let result = tool.result else { return "ждёт результата" }
        return hideContent ? Fmt.bytes(result.outputBytes ?? 0) : result.title
    }
}
