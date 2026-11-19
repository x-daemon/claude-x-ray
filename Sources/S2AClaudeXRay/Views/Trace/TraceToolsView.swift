import Charts
import SwiftUI
import XRayCore

/// Tools, MCP servers (connectors), skills, subagents and files touched in the session.
struct TraceToolsView: View {
    let trace: SessionTrace

    var body: some View {
        let connected = trace.mcpServers.filter { $0.status == .connected }.count
        let invokedSkills = trace.skills.filter { $0.invocations > 0 }.count
        let agentRuns = trace.subagents.reduce(0) { $0 + $1.calls }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatTile(title: L("Вызовов инструментов"), value: "\(trace.tools.count)", caption: L("ошибок \(trace.tools.filter(\.isError).count), сейчас \(trace.tools.filter(\.isRunning).count)"), systemImage: "wrench.and.screwdriver")
                    StatTile(title: L("MCP-серверы"), value: "\(trace.mcpServers.count)", caption: L("подключено \(connected), вызывались \(trace.mcpServers.filter { $0.calls > 0 }.count)"), systemImage: "puzzlepiece.extension")
                    StatTile(title: L("Скиллы"), value: "\(invokedSkills) / \(trace.skills.count)", caption: L("вызваны / доступны"), systemImage: "sparkles")
                    StatTile(title: L("Субагенты"), value: "\(agentRuns)", caption: L("запусков, типов \(trace.subagents.count)"), systemImage: "person.2")
                    StatTile(title: L("Файлы"), value: "\(trace.files.count)", caption: L("прочитано, записано, изменено"), systemImage: "doc.on.doc")
                }

                Card(title: L("Инструменты"), subtitle: L("число вызовов, ошибки, время работы и объём вывода")) {
                    ToolStatsChart(stats: Array(trace.toolStats.prefix(15)))
                    ToolStatsGrid(stats: trace.toolStats)
                }

                Card(title: L("MCP-серверы и коннекторы"), subtitle: L("из списка инструментов сессии и фактических вызовов")) {
                    MCPServersView(servers: trace.mcpServers)
                }

                HStack(alignment: .top, spacing: 16) {
                    Card(title: L("Скиллы"), subtitle: L("подсвечены вызванные")) {
                        SkillsView(skills: trace.skills)
                    }
                    Card(title: L("Субагенты")) {
                        SubagentsView(agents: trace.subagents)
                    }
                    .frame(maxWidth: 420)
                }

                Card(title: L("Файлы"), subtitle: L("последние 60 по времени обращения")) {
                    FilesGrid(files: Array(trace.files.prefix(60)))
                }
            }
            .padding(20)
        }
    }
}

struct ToolStatsChart: View {
    let stats: [ToolStat]

    var body: some View {
        if stats.isEmpty {
            Text(L("Инструменты ещё не вызывались")).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                RankedBarList(rows: stats.map { stat in
                    let ok = Double(stat.calls - stat.errors - stat.running)
                    let segments: [(value: Double, color: Color)] = [
                        (value: ok, color: Palette.tool),
                        (value: Double(stat.errors), color: Palette.critical),
                        (value: Double(stat.running), color: Palette.warning),
                    ].filter { $0.value > 0 }
                    return RankedBarRow(
                        id: stat.name,
                        label: ToolDescriber.displayName(for: stat.name),
                        detail: stat.category.title,
                        value: Double(stat.calls),
                        valueText: L("\(stat.calls) · ср. \(Fmt.shortDuration(stat.averageDuration))"),
                        segments: segments,
                        help: L("успешно \(Int(ok)), ошибок \(stat.errors), выполняется \(stat.running)")
                    )
                })
                HStack(spacing: 14) {
                    Label(L("успех"), systemImage: "square.fill").foregroundStyle(Palette.tool)
                    Label(L("ошибка"), systemImage: "square.fill").foregroundStyle(Palette.critical)
                    Label(L("выполняется"), systemImage: "square.fill").foregroundStyle(Palette.warning)
                }
                .font(.caption)
                .labelStyle(LegendLabelStyle())
            }
        }
    }
}

struct ToolStatsGrid: View {
    let stats: [ToolStat]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                ForEach([L("Инструмент"), L("Категория"), L("Вызовы"), L("Ошибки"), L("Среднее"), L("Максимум"), L("Всего"), L("Генерация ввода"), L("Вывод")], id: \.self) { title in
                    Text(title).foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.medium))
            ForEach(stats) { stat in
                GridRow {
                    Label(ToolDescriber.displayName(for: stat.name), systemImage: TraceStyle.icon(for: stat.category)).lineLimit(1)
                    Text(stat.category.title).foregroundStyle(.secondary)
                    Text("\(stat.calls)" + (stat.running > 0 ? L(" (\(stat.running) идёт)") : "")).monospacedDigit()
                    Text("\(stat.errors)").monospacedDigit().foregroundStyle(stat.errors > 0 ? Palette.critical : Color.primary)
                    Text(Fmt.shortDuration(stat.averageDuration)).monospacedDigit()
                    Text(Fmt.shortDuration(stat.maxDuration)).monospacedDigit()
                    Text(Fmt.shortDuration(stat.totalDuration)).monospacedDigit()
                    Text(stat.inputStreamMs > 0 ? Fmt.ms(stat.inputStreamMs) : "—").monospacedDigit()
                    Text(stat.outputBytes > 0 ? Fmt.bytes(stat.outputBytes) : "—").monospacedDigit()
                }
                .font(.callout)
            }
        }
    }
}

struct MCPServersView: View {
    let servers: [MCPServerUsage]

    var body: some View {
        if servers.isEmpty {
            Text(L("MCP-серверы в этой сессии не встречались")).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(servers) { server in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "puzzlepiece.extension").foregroundStyle(Palette.mcp)
                            Text(server.name).font(.callout.weight(.semibold))
                            Chip(text: server.status.title, systemImage: TraceStyle.icon(for: server.status), tint: TraceStyle.color(for: server.status))
                            if server.hasInstructions {
                                Chip(text: L("есть инструкции"), systemImage: "text.book.closed", tint: Palette.other)
                            }
                            Spacer()
                            Text(L("инструментов \(server.toolsAvailable) · вызовов \(server.calls) · ошибок \(server.errors) · \(Fmt.shortDuration(server.totalDuration))"))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if !server.tools.isEmpty {
                            FlowLayout(spacing: 5) {
                                ForEach(server.tools.sorted { $0.value > $1.value }.map(\.key), id: \.self) { tool in
                                    Chip(text: "\(tool) × \(server.tools[tool] ?? 0)", tint: Palette.mcp)
                                }
                            }
                            .padding(.leading, 24)
                        }
                    }
                    Divider()
                }
            }
        }
    }
}

struct SkillsView: View {
    let skills: [SkillUsage]

    var body: some View {
        if skills.isEmpty {
            Text(L("Список скиллов в логе не найден")).foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(skills) { skill in
                    Chip(
                        text: skill.invocations > 0 ? "\(skill.name) × \(skill.invocations)" : skill.name,
                        systemImage: skill.invocations > 0 ? "sparkles" : nil,
                        tint: skill.invocations > 0 ? Palette.skill : Palette.other
                    )
                    .help(skill.lastUsed.map { L("последний вызов \($0.localized(date: .omitted, time: .standard))") } ?? (skill.available ? L("доступен, не вызывался") : L("вызван, но не в списке")))
                }
            }
        }
    }
}

struct SubagentsView: View {
    let agents: [SubagentUsage]

    var body: some View {
        if agents.isEmpty {
            Text(L("Субагенты не встречались")).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(agents) { agent in
                    GridRow {
                        Image(systemName: agent.calls > 0 ? "person.2.fill" : "person.2").foregroundStyle(agent.calls > 0 ? Palette.subagent : Palette.other)
                        Text(agent.type)
                        Text(agent.calls > 0 ? L("\(agent.calls) запуск. · \(Fmt.shortDuration(agent.totalDuration))") : L("доступен"))
                            .foregroundStyle(.secondary)
                        if agent.running > 0 {
                            Chip(text: L("работает"), systemImage: "hourglass", tint: Palette.warning)
                        } else if agent.errors > 0 {
                            Chip(text: L("ошибок \(agent.errors)"), systemImage: "xmark.circle.fill", tint: Palette.critical)
                        } else {
                            Text("")
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }
}

struct FilesGrid: View {
    let files: [FileTouch]

    var body: some View {
        if files.isEmpty {
            Text(L("Файлы не читались и не менялись")).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach([L("Файл"), L("Чтение"), L("Запись"), L("Правки"), L("Строки"), L("Ошибки"), L("Последнее")], id: \.self) { title in
                        Text(title).foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.medium))
                ForEach(files) { file in
                    GridRow {
                        Text(Snippet.shortPath(file.path))
                            .font(.system(.callout, design: .monospaced))
                            .help(file.path)
                            .lineLimit(1)
                        Text(file.reads > 0 ? "\(file.reads)" : "—").monospacedDigit()
                        Text(file.writes > 0 ? "\(file.writes)" : "—").monospacedDigit()
                        Text(file.edits > 0 ? "\(file.edits)" : "—").monospacedDigit()
                        Text(file.linesAdded + file.linesRemoved > 0 ? "+\(file.linesAdded) −\(file.linesRemoved)" : "—").monospacedDigit()
                        Text(file.errors > 0 ? "\(file.errors)" : "—").foregroundStyle(file.errors > 0 ? Palette.critical : Color.secondary)
                        Text(file.last.localized(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}
