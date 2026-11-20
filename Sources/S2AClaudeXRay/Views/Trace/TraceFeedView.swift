import SwiftUI
import XRayCore

/// One row of the live feed: an item, its tool execution (call + result) and, on the
/// first block of a model response, that response's usage.
struct FeedRow: Identifiable {
    let item: ActivityItem
    let tool: ToolExecution?
    let usage: PricedEvent?
    var id: String { item.id }
}

enum FeedFilter: String, CaseIterable, Identifiable {
    case all, user, model, tools, context, errors

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return L("Всё")
        case .user: return L("Вы")
        case .model: return L("Модель")
        case .tools: return L("Инструменты")
        case .context: return L("Контекст и система")
        case .errors: return L("Ошибки")
        }
    }

    func matches(_ item: ActivityItem) -> Bool {
        switch self {
        case .all: return true
        case .user: return [.prompt, .queued, .interrupted].contains(item.kind)
        case .model: return [.thinking, .reply].contains(item.kind)
        case .tools: return [.toolCall, .toolResult].contains(item.kind)
        case .context: return [.context, .compact, .hook, .note].contains(item.kind)
        case .errors: return item.isError || item.kind == .apiError || item.kind == .interrupted
        }
    }
}

/// Reverse-chronological feed of everything that happened, newest first.
struct TraceFeedView: View {
    let trace: SessionTrace
    let usage: [String: PricedEvent]
    let hideContent: Bool

    @State private var filter: FeedFilter = .all
    @State private var query = ""
    @State private var limit = 250
    @State private var expanded: Set<String> = []

    private var filterPicker: some View {
        Picker(L("Фильтр"), selection: $filter) {
            ForEach(FeedFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var searchField: some View {
        TextField(L("Поиск по командам, файлам, текстам"), text: $query)
            .textFieldStyle(.roundedBorder)
    }

    private func eventCount(_ count: Int) -> some View {
        Text(L("\(count) событий")).font(.caption).foregroundStyle(.secondary).fixedSize()
    }

    var body: some View {
        let rows = makeRows()

        VStack(spacing: 0) {
            // One row when the filters keep their full titles; on a narrow screen (an iPad in
            // portrait) the search goes below them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterPicker.frame(maxWidth: 560)
                    searchField.frame(maxWidth: 280)
                    Spacer()
                    eventCount(rows.count)
                }
                VStack(alignment: .leading, spacing: 8) {
                    filterPicker
                    HStack(spacing: 12) {
                        searchField
                        eventCount(rows.count)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.prefix(limit)) { row in
                        FeedRowView(
                            row: row,
                            hideContent: hideContent,
                            isExpanded: expanded.contains(row.id),
                            toggle: { toggle(row.id) }
                        )
                        Divider()
                    }
                    if rows.count > limit {
                        Button(L("Показать ещё \(min(250, rows.count - limit))")) { limit += 250 }
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func makeRows() -> [FeedRow] {
        let toolsByCall = Dictionary(trace.tools.map { ($0.call.id, $0) }, uniquingKeysWith: { first, _ in first })
        let answeredCalls = Set(trace.tools.compactMap { $0.result == nil ? nil : $0.call.toolUseID })
        var seenMessages = Set<String>()
        let needle = query.trimmingCharacters(in: .whitespaces)

        var rows: [FeedRow] = []
        for item in trace.items {
            // Results are shown inside their tool call row.
            if item.kind == .toolResult, let id = item.toolUseID, answeredCalls.contains(id), item.messageID == nil {
                continue
            }
            var rowUsage: PricedEvent?
            if let messageID = item.messageID, seenMessages.insert(messageID).inserted {
                rowUsage = usage[messageID]
            }
            let tool = toolsByCall[item.id]
            let row = FeedRow(item: item, tool: tool, usage: rowUsage)
            guard filter.matches(item) || (filter == .errors && tool?.isError == true) else { continue }
            if !needle.isEmpty {
                let haystack = [item.title, item.detail ?? "", item.target ?? "", tool?.result?.detail ?? ""].joined(separator: "\n")
                guard haystack.localizedCaseInsensitiveContains(needle) else { continue }
            }
            rows.append(row)
        }
        return rows.reversed()
    }
}

struct FeedRowView: View {
    let row: FeedRow
    let hideContent: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        let item = row.item
        let isError = item.isError || row.tool?.isError == true

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.timestamp.localized(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .leading)
                Image(systemName: row.tool.map { TraceStyle.icon(for: $0.category) } ?? TraceStyle.icon(for: item.kind))
                    .foregroundStyle(isError ? Palette.critical : TraceStyle.color(for: item.kind))
                    .frame(width: 18)
                Text(TraceText.title(for: item, hideContent: hideContent))
                    .font(item.kind == .toolCall ? .system(.callout, design: .monospaced) : .callout)
                    .lineLimit(isExpanded ? 6 : 1)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if let tool = row.tool {
                    ToolStatusChip(tool: tool)
                }
                if hasDetail {
                    Button(action: toggle) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? L("Свернуть") : L("Подробнее"))
                }
            }

            FlowLayout(spacing: 5) {
                ForEach(TraceText.chips(for: item, tool: row.tool), id: \.text) { chip in
                    Chip(text: chip.text, systemImage: chip.icon, tint: chip.tint)
                }
            }
            .padding(.leading, 92)

            if let usage = row.usage {
                UsageLine(priced: usage)
                    .padding(.leading, 92)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !hideContent, let detail = item.detail {
                        DetailBlock(text: detail)
                    }
                    if let result = row.tool?.result {
                        Text(result.isError ? L("Результат (ошибка)") : L("Результат"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(result.isError ? Palette.critical : .secondary)
                        DetailBlock(text: hideContent ? L("\(Fmt.bytes(result.outputBytes ?? 0)) скрыто") : (result.detail ?? result.title))
                    }
                    if hideContent {
                        Text(L("Содержимое скрыто переключателем «Скрыть содержимое».")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 92)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if hasDetail { toggle() } }
    }

    private var hasDetail: Bool {
        row.item.detail != nil || row.tool?.result != nil
    }
}

/// ✓ 1.2 с / ✗ ошибка / ⏳ выполняется.
struct ToolStatusChip: View {
    let tool: ToolExecution

    var body: some View {
        if tool.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Chip(text: L("выполняется \(Fmt.shortDuration(tool.duration(now: timeline.date)))"), systemImage: "hourglass", tint: Palette.warning)
            }
        } else if tool.isError {
            Chip(text: L("ошибка · \(Fmt.shortDuration(tool.duration(now: Date())))"), systemImage: "xmark.circle.fill", tint: Palette.critical)
        } else {
            Chip(text: Fmt.shortDuration(tool.duration(now: Date())), systemImage: "checkmark.circle.fill", tint: Palette.good)
        }
    }
}

/// Tokens, context and cost of one model response.
struct UsageLine: View {
    let priced: PricedEvent

    var body: some View {
        let t = priced.event.tokens
        let window = ModelCatalog.contextWindow(for: priced.event.model)
        var parts = [
            L("контекст \(Fmt.tokens(t.contextTokens)) (\(Fmt.percent(Double(t.contextTokens) / Double(window))) окна)"),
            L("из кэша \(Fmt.percent(t.cacheHitRate))"),
        ]
        if t.cacheWrite > 0 { parts.append(L("запись в кэш \(Fmt.tokens(t.cacheWrite))\(t.cacheWrite1h > 0 ? L(" (1 ч)") : "")")) }
        parts.append(L("ввод \(Fmt.tokens(t.input))"))
        parts.append(L("вывод \(Fmt.tokens(t.output))") + (t.thinking > 0 ? L(" (размышления \(Fmt.tokens(t.thinking)))") : ""))
        if priced.event.webSearchRequests > 0 { parts.append(L("веб-поиск \(priced.event.webSearchRequests)")) }
        parts.append(Fmt.usd(priced.cost.total))

        return HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(Palette.model)
            Text(parts.joined(separator: " · "))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// Titles and chips shared by the feed and the flow tree.
enum TraceText {
    struct ChipSpec {
        let text: String
        let icon: String?
        let tint: Color
    }

    static func title(for item: ActivityItem, hideContent: Bool) -> String {
        guard hideContent else { return item.title }
        switch item.kind {
        case .prompt, .queued: return L("\(TraceStyle.label(for: item.kind)) · \(item.detail?.count ?? item.title.count) символов")
        case .reply: return L("Ответ · \(item.detail?.count ?? item.title.count) символов")
        case .thinking: return L("Размышление")
        case .toolCall: return item.toolName.map { ToolDescriber.mcpServer(of: $0).map { "MCP \($0)" } ?? $0 } ?? L("Инструмент")
        case .toolResult: return L("Результат · \(Fmt.bytes(item.outputBytes ?? 0))")
        default: return item.title
        }
    }

    static func chips(for item: ActivityItem, tool: ToolExecution?) -> [ChipSpec] {
        var chips: [ChipSpec] = [ChipSpec(text: TraceStyle.label(for: item.kind), icon: nil, tint: TraceStyle.color(for: item.kind))]
        if item.isSidechain { chips.append(ChipSpec(text: L("субагент"), icon: "person.2", tint: Palette.subagent)) }
        if let model = item.model, item.kind == .thinking || item.kind == .reply || item.kind == .toolCall {
            chips.append(ChipSpec(text: ModelCatalog.displayName(for: model), icon: "cpu", tint: Palette.model))
        }
        if let requested = item.requestedModel, let model = item.model, PricingTable.normalize(requested) != PricingTable.normalize(model) {
            chips.append(ChipSpec(text: L("запрошена \(ModelCatalog.displayName(for: requested))"), icon: "arrow.triangle.swap", tint: Palette.warning))
        }
        if let effort = item.effort, item.kind == .thinking || item.kind == .reply { chips.append(ChipSpec(text: "effort \(effort)", icon: "dial.medium", tint: Palette.other)) }
        if let ms = item.thinkingMs, ms > 0 { chips.append(ChipSpec(text: L("думал \(Fmt.ms(ms))"), icon: "brain", tint: Palette.model)) }
        if let ms = item.inputStreamMs, ms > 0 { chips.append(ChipSpec(text: L("ввод генерировался \(Fmt.ms(ms))"), icon: "keyboard", tint: Palette.other)) }
        if let server = item.mcpServer { chips.append(ChipSpec(text: "MCP \(server)", icon: "puzzlepiece.extension", tint: Palette.mcp)) }
        if let skill = item.attributionSkill { chips.append(ChipSpec(text: L("скилл \(skill)"), icon: "sparkles", tint: Palette.skill)) }
        if let action = item.fileAction, let path = item.target {
            let verb: String
            switch action {
            case .read: verb = L("чтение")
            case .write: verb = L("запись")
            case .edit: verb = L("правка")
            }
            chips.append(ChipSpec(text: "\(verb) \(Snippet.shortPath(path))", icon: "doc", tint: Palette.other))
        }
        if let result = tool?.result {
            if let added = result.linesAdded, let removed = result.linesRemoved {
                chips.append(ChipSpec(text: L("+\(added) −\(removed) строк"), icon: "plusminus", tint: Palette.other))
            } else if let added = result.linesAdded {
                chips.append(ChipSpec(text: L("+\(added) строк"), icon: "plus", tint: Palette.other))
            }
            if let bytes = result.outputBytes, bytes > 0 {
                chips.append(ChipSpec(text: L("вывод \(Fmt.bytes(bytes)) ≈\(Fmt.tokens(bytes / 4)) ток."), icon: "arrow.turn.down.left", tint: Palette.other))
            }
            if let permission = result.permission {
                chips.append(ChipSpec(text: permission, icon: "lock.open", tint: Palette.other))
            }
        }
        if item.kind == .toolResult, let bytes = item.outputBytes, tool == nil {
            chips.append(ChipSpec(text: Fmt.bytes(bytes), icon: nil, tint: Palette.other))
        }
        if let stop = item.stopReason, item.kind == .reply, stop != "tool_use" {
            chips.append(ChipSpec(text: "stop: \(stop)", icon: nil, tint: Palette.other))
        }
        return chips
    }
}
