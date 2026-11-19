import Charts
import SwiftUI
import XRayCore

/// Context window: fill, composition, per-request split, what inflates it, environment and permissions.
struct TraceContextView: View {
    let trace: SessionTrace
    let usage: [String: PricedEvent]

    var body: some View {
        let events = usage.values.sorted { $0.event.timestamp < $1.event.timestamp }
        let main = events.filter { !$0.event.isSidechain }
        let last = main.last ?? events.last
        let window = last.map { ModelCatalog.contextWindow(for: $0.event.model) } ?? 1_000_000
        let contextNow = last?.event.tokens.contextTokens ?? 0
        let ratio = Double(contextNow) / Double(max(window, 1))
        let snapshot = trace.context

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatTile(title: L("Контекст сейчас"), value: Fmt.tokens(contextNow), caption: L("\(Fmt.percent(ratio)) окна \(Fmt.tokens(window))"), systemImage: "gauge.with.dots.needle.50percent")
                    StatTile(
                        title: L("Модель"),
                        value: snapshot.modelName ?? last.map { ModelCatalog.displayName(for: $0.event.model) } ?? "—",
                        caption: [snapshot.modelID ?? last?.event.model, snapshot.knowledgeCutoff.map { L("знания до \($0)") }].compactMap { $0 }.joined(separator: " · "),
                        systemImage: "cpu"
                    )
                    StatTile(title: "Effort", value: last?.event.effort ?? "—", caption: L("глубина размышлений"), systemImage: "dial.medium")
                    StatTile(
                        title: L("Кэш последнего запроса"),
                        value: last.map { Fmt.percent($0.event.tokens.cacheHitRate) } ?? "—",
                        caption: (last?.event.tokens.cacheWrite1h ?? 0) > 0 ? L("запись с TTL 1 ч") : L("TTL 5 мин"),
                        systemImage: "memorychip"
                    )
                    StatTile(title: L("Сжатий контекста"), value: "\(snapshot.compactions)", caption: L("/compact и автоматические"), systemImage: "arrow.down.right.and.arrow.up.left")
                }

                Card(title: L("Заполнение окна контекста"), subtitle: L("\(Fmt.tokens(contextNow)) из \(Fmt.tokens(window))")) {
                    UsageBar(fraction: ratio, color: ratio >= 0.8 ? Palette.critical : ratio >= 0.6 ? Palette.warning : Palette.primary)
                    Text(ratio >= 0.6
                         ? L("Контекст заполнен больше чем на \(Fmt.percent(ratio)). Каждый следующий ход отправляет его целиком; подумайте о /compact или новой сессии.")
                         : L("Каждый ход заново отправляет весь контекст; чем он меньше, тем дешевле и быстрее ответы."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card(title: L("Из чего состоит контекст"), subtitle: L("оценка ≈ 4 символа на токен")) {
                    ContextCompositionView(snapshot: snapshot, total: contextNow)
                }

                Card(title: L("Контекст по запросам"), subtitle: L("последние 80 запросов: чтение кэша, запись в кэш, свежий ввод")) {
                    ContextSplitChart(events: Array(main.suffix(80)))
                }

                Card(title: L("Что сильнее всего раздувает контекст"), subtitle: L("самые большие результаты инструментов")) {
                    BiggestResultsView(trace: trace)
                }

                HStack(alignment: .top, spacing: 16) {
                    Card(title: L("Окружение")) {
                        EnvironmentGrid(snapshot: snapshot, trace: trace)
                    }
                    Card(title: L("Разрешения")) {
                        PermissionsView(trace: trace)
                    }
                }

                if !snapshot.editedFiles.isEmpty {
                    Card(title: L("Файлы, изменённые вне Claude"), subtitle: L("Claude получает об этом уведомление в контексте")) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(snapshot.editedFiles, id: \.self) { path in
                                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

/// Known parts (system prompt, listings) vs the rest (conversation, tool results, tool schemas).
struct ContextCompositionView: View {
    let snapshot: ContextSnapshot
    let total: Int

    private struct Part: Identifiable {
        let name: String
        let tokens: Int
        var id: String { name }
    }

    var body: some View {
        let known = snapshot.knownComponents.map { Part(name: $0.name, tokens: $0.tokens) }
        let knownTotal = known.reduce(0) { $0 + $1.tokens }
        let parts = known + (total > knownTotal ? [Part(name: L("Диалог, результаты инструментов, схемы"), tokens: total - knownTotal)] : [])
        let domain = parts.map(\.name)
        let range = parts.indices.map { index in
            index < known.count ? Palette.series[index % Palette.series.count] : Palette.other
        }

        VStack(alignment: .leading, spacing: 10) {
            if parts.isEmpty {
                Text(L("В транскрипте пока нет сведений о составе контекста")).foregroundStyle(.secondary)
            } else {
                Chart(parts) { part in
                    BarMark(x: .value(L("Токены"), part.tokens), y: .value(L("Контекст"), L("Контекст")))
                        .foregroundStyle(by: .value(L("Часть"), part.name))
                }
                .chartForegroundStyleScale(domain: domain, range: range)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Palette.hairline)
                        AxisValueLabel {
                            if let amount = value.as(Int.self) { Text(Fmt.tokens(amount)) }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 50)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                        GridRow {
                            RoundedRectangle(cornerRadius: 2).fill(range[index]).frame(width: 10, height: 10)
                            Text(part.name)
                            Text("≈\(Fmt.tokens(part.tokens))").monospacedDigit()
                            Text(total > 0 ? Fmt.percent(Double(part.tokens) / Double(total)) : "—").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
            Text(L("Скиллов в контексте: \(snapshot.skills.count) · отложенных инструментов: \(snapshot.deferredTools.count) · типов субагентов: \(snapshot.subagentTypes.count) · MCP с инструкциями: \(snapshot.mcpWithInstructions.count)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Stacked bars per request: cache read, cache write, fresh input.
struct ContextSplitChart: View {
    let events: [PricedEvent]

    private struct Segment: Identifiable {
        let index: Int
        let kind: String
        let tokens: Double
        var id: String { "\(index)-\(kind)" }
    }

    var body: some View {
        let segments = events.enumerated().flatMap { index, priced -> [Segment] in
            let t = priced.event.tokens
            return [
                Segment(index: index + 1, kind: L("Чтение кэша"), tokens: Double(t.cacheRead)),
                Segment(index: index + 1, kind: L("Запись в кэш"), tokens: Double(t.cacheWrite)),
                Segment(index: index + 1, kind: L("Свежий ввод"), tokens: Double(t.input)),
            ]
        }

        let barWidth = CGFloat(max(2, min(14, 900 / max(events.count, 1) - 2)))

        if segments.isEmpty {
            Text(L("Нет запросов")).foregroundStyle(.secondary)
        } else {
            Chart(segments) { segment in
                BarMark(x: .value(L("Запрос"), segment.index), y: .value(L("Токены"), segment.tokens), width: .fixed(barWidth))
                    .foregroundStyle(by: .value(L("Часть"), segment.kind))
            }
            .chartForegroundStyleScale(domain: [L("Чтение кэша"), L("Запись в кэш"), L("Свежий ввод")], range: [Palette.component(L("Чтение кэша")), Palette.component(L("Запись в кэш")), Palette.component(L("Ввод"))])
            .tokenYAxis()
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 190)
        }
    }
}

/// Largest tool outputs: each one stays in the context for the rest of the session.
struct BiggestResultsView: View {
    let trace: SessionTrace

    var body: some View {
        let biggest = trace.tools
            .filter { ($0.result?.outputBytes ?? 0) > 0 }
            .sorted { ($0.result?.outputBytes ?? 0) > ($1.result?.outputBytes ?? 0) }
            .prefix(10)

        if biggest.isEmpty {
            Text(L("Результатов инструментов пока нет")).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text(L("Инструмент")).foregroundStyle(.secondary)
                    Text(L("Что")).foregroundStyle(.secondary)
                    Text(L("Размер")).foregroundStyle(.secondary)
                    Text(L("≈ токенов")).foregroundStyle(.secondary)
                    Text(L("Когда")).foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
                ForEach(Array(biggest)) { tool in
                    let bytes = tool.result?.outputBytes ?? 0
                    GridRow {
                        Text(tool.mcpServer.map { "MCP \($0)" } ?? tool.name)
                        Text(Snippet.truncate(tool.call.title, 70)).font(.system(.caption, design: .monospaced)).lineLimit(1)
                        Text(Fmt.bytes(bytes)).monospacedDigit()
                        Text(Fmt.tokens(bytes / 4)).monospacedDigit()
                        Text(tool.start.localized(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            Text(L("Большие выводы (чтение целых файлов, длинные логи) остаются в контексте до /compact или конца сессии. Читайте файлы частями и фильтруйте вывод команд."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct EnvironmentGrid: View {
    let snapshot: ContextSnapshot
    let trace: SessionTrace

    var body: some View {
        let env = snapshot.environment
        let rows: [(String, String)] = [
            (L("Рабочая папка"), env["workingDirectory"] ?? trace.projectPath ?? "—"),
            (L("Ветка git"), trace.gitBranch ?? "—"),
            (L("Git-репозиторий"), env["isGitRepo"] ?? "—"),
            ("Worktree", env["isWorktree"] ?? "—"),
            (L("Платформа"), [env["platform"], env["osVersion"]].compactMap { $0 }.joined(separator: " · ")),
            (L("Оболочка"), env["shell"] ?? "—"),
            (L("Доп. папки"), env["additionalWorkingDirectories"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
            (L("Задач в списке"), snapshot.taskCount.map(String.init) ?? "—"),
            (L("Последнее изменение"), snapshot.lastRemoteChange ?? "—"),
        ]
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1.isEmpty ? "—" : row.1).textSelection(.enabled).lineLimit(2)
                }
            }
        }
        .font(.callout)
    }
}

struct PermissionsView: View {
    let trace: SessionTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if trace.permissions.isEmpty {
                Text(L("Решений о разрешениях в логе нет")).foregroundStyle(.secondary)
            } else {
                Text(L("Как разрешались вызовы инструментов")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(trace.permissions) { permission in
                    HStack {
                        Image(systemName: permission.label.hasPrefix("accept") ? "checkmark.shield" : "hand.raised").foregroundStyle(Palette.primary)
                        Text(permission.label)
                        Spacer()
                        Text("\(permission.count)").monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            if let flags = trace.context.autoMode {
                Divider()
                Text("Auto mode").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                FlowLayout(spacing: 5) {
                    ForEach(flags.keys.sorted(), id: \.self) { key in
                        Chip(text: "\(key): \(flags[key] ?? "")", tint: Palette.other)
                    }
                }
            }
            if !trace.context.allowedRules.isEmpty {
                Divider()
                Text(L("Разрешённые правила")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(trace.context.allowedRules, id: \.self) { rule in
                    Text(rule).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }
}
