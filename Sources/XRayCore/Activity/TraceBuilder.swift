import Foundation

/// Builds a `SessionTrace` from a session's activity items.
public enum TraceBuilder {
    /// No activity for this long counts as idle.
    public static let defaultIdleAfter: TimeInterval = 10 * 60
    /// A tool call without a result older than this is treated as abandoned.
    public static let runningToolTimeout: TimeInterval = 30 * 60

    public static func build(
        sessionID: String,
        items unsorted: [ActivityItem],
        now: Date = Date(),
        idleAfter: TimeInterval = defaultIdleAfter
    ) -> SessionTrace {
        let items = unsorted.enumerated()
            .sorted { $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp }
            .map(\.element)

        var trace = SessionTrace(sessionID: sessionID)
        trace.items = items
        trace.tools = tools(items)
        trace.steps = steps(items)
        trace.context = context(items)
        trace.turns = turns(items, tools: trace.tools, steps: trace.steps, now: now, idleAfter: idleAfter)
        trace.files = files(trace.tools)
        trace.toolStats = toolStats(trace.tools, now: now)
        trace.mcpServers = mcpServers(trace.tools, context: trace.context, now: now)
        trace.skills = skills(trace.tools, steps: trace.steps, context: trace.context)
        trace.subagents = subagents(trace.tools, context: trace.context, now: now)
        trace.permissions = permissions(items)
        trace.transitions = transitions(items, tools: trace.tools)
        trace.status = status(sessionID: sessionID, items: items, tools: trace.tools, now: now, idleAfter: idleAfter)
        trace.errors = items.filter(\.isError).count
        trace.prompts = items.filter { $0.kind == .prompt && !$0.isSidechain }.count
        return trace
    }

    // MARK: Tools and steps

    static func tools(_ items: [ActivityItem]) -> [ToolExecution] {
        var results: [String: ActivityItem] = [:]
        for item in items where item.kind == .toolResult {
            if let id = item.toolUseID { results[id] = item }
        }
        return items.compactMap { item in
            guard item.kind == .toolCall else { return nil }
            return ToolExecution(call: item, result: item.toolUseID.flatMap { results[$0] })
        }
    }

    static func steps(_ items: [ActivityItem]) -> [ModelStep] {
        var order: [String] = []
        var byID: [String: ModelStep] = [:]
        // The model starts working when its input arrives: a prompt, a tool result, a delivered message.
        var lastInput: [Bool: Date] = [:]

        for item in items {
            switch item.kind {
            case .prompt, .queued, .compact:
                lastInput[item.isSidechain] = item.timestamp
                continue
            case .toolResult where item.messageID == nil:
                lastInput[item.isSidechain] = item.timestamp
                continue
            default:
                break
            }
            guard let messageID = item.messageID else { continue }

            if var step = byID[messageID] {
                step.end = max(step.end, item.timestamp)
                absorb(item, into: &step)
                byID[messageID] = step
            } else {
                var start = lastInput[item.isSidechain] ?? item.timestamp
                if start > item.timestamp { start = item.timestamp }
                var step = ModelStep(
                    messageID: messageID, model: nil, requestedModel: nil, effort: nil,
                    start: start, end: item.timestamp, thinkingMs: 0, inputStreamMs: 0,
                    toolCallIDs: [], replyText: nil, stopReason: nil,
                    isSidechain: item.isSidechain, attributionSkill: nil
                )
                absorb(item, into: &step)
                byID[messageID] = step
                order.append(messageID)
                // The next response starts after this one unless new input arrives.
            }
            lastInput[item.isSidechain] = item.timestamp
        }
        return order.compactMap { byID[$0] }
    }

    private static func absorb(_ item: ActivityItem, into step: inout ModelStep) {
        step.model = step.model ?? item.model
        step.requestedModel = step.requestedModel ?? item.requestedModel
        step.effort = step.effort ?? item.effort
        step.attributionSkill = step.attributionSkill ?? item.attributionSkill
        if let reason = item.stopReason { step.stopReason = reason }
        step.thinkingMs += item.thinkingMs ?? 0
        step.inputStreamMs += item.inputStreamMs ?? 0
        if item.kind == .toolCall { step.toolCallIDs.append(item.id) }
        if item.kind == .reply { step.replyText = item.detail ?? item.title }
    }

    // MARK: Turns and flow tree

    static func turns(_ items: [ActivityItem], tools: [ToolExecution], steps: [ModelStep], now: Date, idleAfter: TimeInterval) -> [TraceTurn] {
        let toolByCall = Dictionary(tools.map { ($0.call.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stepByID = Dictionary(steps.map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first })

        // Split at user prompts of the main thread.
        var groups: [[ActivityItem]] = []
        for item in items {
            if (item.kind == .prompt && !item.isSidechain) || groups.isEmpty {
                groups.append([item])
            } else {
                groups[groups.count - 1].append(item)
            }
        }

        let lastActivity = items.last?.timestamp ?? now
        return groups.enumerated().map { index, group in
            let prompt = group.first { $0.kind == .prompt && !$0.isSidechain }
            var nodes: [FlowNode] = []
            var openStep: (id: String, children: [FlowNode])?
            var stepIDs: [String] = []

            func closeStep() {
                if let open = openStep, let step = stepByID[open.id] {
                    nodes.append(.step(step, children: open.children))
                }
                openStep = nil
            }

            for item in group {
                if let prompt, item.id == prompt.id { continue }
                if let messageID = item.messageID {
                    if openStep?.id != messageID {
                        closeStep()
                        openStep = (id: messageID, children: [])
                        if !stepIDs.contains(messageID) { stepIDs.append(messageID) }
                    }
                    let child: FlowNode
                    if item.kind == .toolCall, let tool = toolByCall[item.id] {
                        child = .tool(tool)
                    } else {
                        child = .item(item)
                    }
                    openStep?.children.append(child)
                    continue
                }
                // A tool result is shown inside its tool call.
                if item.kind == .toolResult { continue }
                closeStep()
                nodes.append(.item(item))
            }
            closeStep()

            let toolCalls = group.filter { $0.kind == .toolCall }.count
            let errors = group.filter(\.isError).count
            let last = group.last
            let outcome: TurnOutcome
            if group.contains(where: { $0.kind == .interrupted }) {
                outcome = .interrupted
            } else if last?.kind == .apiError {
                outcome = .failed
            } else if index == groups.count - 1, now.timeIntervalSince(lastActivity) < idleAfter,
                      !(last?.kind == .reply && last?.stopReason == "end_turn") {
                outcome = .inProgress
            } else {
                outcome = .completed
            }

            return TraceTurn(
                id: group.first?.id ?? "turn-\(index)",
                index: index,
                prompt: prompt,
                start: group.first?.timestamp ?? now,
                end: group.last?.timestamp ?? now,
                nodes: nodes,
                stepIDs: stepIDs,
                toolCalls: toolCalls,
                errors: errors,
                outcome: outcome
            )
        }
    }

    // MARK: Aggregates

    static func files(_ tools: [ToolExecution]) -> [FileTouch] {
        var byPath: [String: FileTouch] = [:]
        for tool in tools {
            guard let action = tool.call.fileAction, let path = tool.call.target, !path.isEmpty else { continue }
            var touch = byPath[path] ?? FileTouch(path: path, last: tool.start)
            switch action {
            case .read: touch.reads += 1
            case .write: touch.writes += 1
            case .edit: touch.edits += 1
            }
            if tool.isError { touch.errors += 1 }
            touch.linesAdded += tool.result?.linesAdded ?? 0
            touch.linesRemoved += tool.result?.linesRemoved ?? 0
            touch.last = max(touch.last, tool.start)
            byPath[path] = touch
        }
        return byPath.values.sorted { $0.last > $1.last }
    }

    static func toolStats(_ tools: [ToolExecution], now: Date) -> [ToolStat] {
        var byName: [String: ToolStat] = [:]
        for tool in tools {
            var stat = byName[tool.name] ?? ToolStat(name: tool.name, category: tool.category)
            stat.calls += 1
            if tool.isError { stat.errors += 1 }
            if tool.isRunning {
                stat.running += 1
            } else {
                let duration = tool.duration(now: now)
                stat.totalDuration += duration
                stat.maxDuration = max(stat.maxDuration, duration)
            }
            stat.inputStreamMs += tool.call.inputStreamMs ?? 0
            stat.outputBytes += tool.result?.outputBytes ?? 0
            byName[tool.name] = stat
        }
        return byName.values.sorted { $0.calls == $1.calls ? $0.name < $1.name : $0.calls > $1.calls }
    }

    static func context(_ items: [ActivityItem]) -> ContextSnapshot {
        var snapshot = ContextSnapshot()
        var deferred = Set<String>()
        var skills = Set<String>()
        var agents = Set<String>()
        var instructions = Set<String>()

        for item in items {
            if item.kind == .compact { snapshot.compactions += 1 }
            guard let payload = item.context else { continue }
            switch payload {
            case let .tools(added, removed, pending, failed, needsAuth, chars):
                deferred.formUnion(added)
                deferred.subtract(removed)
                snapshot.toolListingChars += chars
                snapshot.pendingMCP = pending
                snapshot.failedMCP = failed
                snapshot.needsAuthMCP = needsAuth
            case let .skills(names, _, chars):
                skills.formUnion(names)
                snapshot.skillListingChars = chars
            case let .mcpInstructions(added, removed, chars):
                instructions.formUnion(added)
                instructions.subtract(removed)
                snapshot.mcpInstructionChars += chars
            case let .agents(added, removed, chars):
                agents.formUnion(added)
                agents.subtract(removed)
                snapshot.agentListingChars += chars
            case let .systemPrompt(chars, _):
                snapshot.systemPromptChars = chars
            case .environment(let values):
                snapshot.environment.merge(values) { _, new in new }
            case let .model(id, name, cutoff):
                snapshot.modelID = id
                snapshot.modelName = name
                snapshot.knowledgeCutoff = cutoff
            case .autoMode(let flags):
                snapshot.autoMode = flags
            case .permissions(let allowed):
                snapshot.allowedRules = allowed
            case .editedFile(let path):
                if !snapshot.editedFiles.contains(path) { snapshot.editedFiles.append(path) }
            case .tasks(let count):
                snapshot.taskCount = count
            case let .remoteChange(commit, pullRequest, url):
                snapshot.lastRemoteChange = [commit, pullRequest, url].compactMap { $0 }.first
            }
        }
        snapshot.deferredTools = deferred.sorted()
        snapshot.skills = skills.sorted()
        snapshot.subagentTypes = agents.sorted()
        snapshot.mcpWithInstructions = instructions.sorted()
        return snapshot
    }

    static func mcpServers(_ tools: [ToolExecution], context: ContextSnapshot, now: Date) -> [MCPServerUsage] {
        var servers: [String: MCPServerUsage] = [:]
        for name in context.deferredTools {
            guard let server = ToolDescriber.mcpServer(of: name) else { continue }
            servers[server, default: MCPServerUsage(name: server, status: .connected)].toolsAvailable += 1
        }
        for name in context.mcpWithInstructions {
            servers[name, default: MCPServerUsage(name: name, status: .connected)].hasInstructions = true
        }
        for tool in tools {
            guard let server = tool.mcpServer else { continue }
            var usage = servers[server] ?? MCPServerUsage(name: server, status: .usedOnly)
            usage.calls += 1
            if tool.isError { usage.errors += 1 }
            usage.totalDuration += tool.duration(now: now)
            usage.tools[ToolDescriber.mcpTool(of: tool.name) ?? tool.name, default: 0] += 1
            servers[server] = usage
        }
        for name in context.pendingMCP { servers[name, default: MCPServerUsage(name: name, status: .pending)].status = .pending }
        for name in context.needsAuthMCP { servers[name, default: MCPServerUsage(name: name, status: .needsAuth)].status = .needsAuth }
        for name in context.failedMCP { servers[name, default: MCPServerUsage(name: name, status: .failed)].status = .failed }
        return servers.values.sorted { $0.calls == $1.calls ? $0.name.lowercased() < $1.name.lowercased() : $0.calls > $1.calls }
    }

    static func skills(_ tools: [ToolExecution], steps: [ModelStep], context: ContextSnapshot) -> [SkillUsage] {
        var skills: [String: SkillUsage] = [:]
        for name in context.skills {
            skills[name, default: SkillUsage(name: name)].available = true
        }
        for tool in tools where tool.name == "Skill" {
            let name = tool.call.target ?? "?"
            var usage = skills[name] ?? SkillUsage(name: name)
            usage.invocations += 1
            usage.lastUsed = max(usage.lastUsed ?? tool.start, tool.start)
            skills[name] = usage
        }
        for step in steps {
            guard let name = step.attributionSkill else { continue }
            skills[name, default: SkillUsage(name: name)].attributedSteps += 1
        }
        return skills.values.sorted {
            if $0.invocations != $1.invocations { return $0.invocations > $1.invocations }
            return $0.name < $1.name
        }
    }

    static func subagents(_ tools: [ToolExecution], context: ContextSnapshot, now: Date) -> [SubagentUsage] {
        var agents: [String: SubagentUsage] = [:]
        for type in context.subagentTypes {
            agents[type, default: SubagentUsage(type: type)].available = true
        }
        for tool in tools where tool.category == .agent && tool.name != "SendMessage" {
            let type = tool.call.target ?? "general-purpose"
            var usage = agents[type] ?? SubagentUsage(type: type)
            usage.calls += 1
            if tool.isRunning { usage.running += 1 }
            if tool.isError { usage.errors += 1 }
            usage.totalDuration += tool.duration(now: now)
            agents[type] = usage
        }
        return agents.values.sorted { $0.calls == $1.calls ? $0.type < $1.type : $0.calls > $1.calls }
    }

    static func permissions(_ items: [ActivityItem]) -> [PermissionStat] {
        var counts: [String: Int] = [:]
        for item in items {
            if let label = item.permission { counts[label, default: 0] += 1 }
        }
        return counts.map { PermissionStat(label: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    /// Node label used by the flow map.
    static func flowNode(for tool: ToolExecution) -> String {
        if let server = tool.mcpServer { return "MCP: \(server)" }
        switch tool.category {
        case .agent: return "Субагент"
        case .skill: return "Скилл"
        default: return tool.name
        }
    }

    static func transitions(_ items: [ActivityItem], tools: [ToolExecution]) -> [FlowTransition] {
        let toolByCall = Dictionary(tools.map { ($0.call.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sequence: [String] = []
        var lastMessage: String?
        for item in items where !item.isSidechain {
            switch item.kind {
            case .prompt: sequence.append("Промпт"); lastMessage = nil
            case .queued where item.title.hasPrefix("Передано"): sequence.append("Сообщение во время работы")
            case .interrupted: sequence.append("Прерывание")
            case .compact: sequence.append("Сжатие контекста")
            case .apiError: sequence.append("Ошибка API")
            case .thinking, .reply, .toolCall:
                if let id = item.messageID, id != lastMessage {
                    sequence.append("Модель")
                    lastMessage = id
                }
                if item.kind == .toolCall, let tool = toolByCall[item.id] {
                    sequence.append(flowNode(for: tool))
                    if tool.isError { sequence.append("Ошибка инструмента") }
                }
                if item.kind == .reply, item.stopReason == "end_turn" { sequence.append("Ответ") }
            default:
                continue
            }
        }
        var counts: [String: FlowTransition] = [:]
        for (from, to) in zip(sequence, sequence.dropFirst()) where from != to {
            counts["\(from)|\(to)", default: FlowTransition(from: from, to: to, count: 0)].count += 1
        }
        return counts.values.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }

    // MARK: Live status

    static func status(sessionID: String, items: [ActivityItem], tools: [ToolExecution], now: Date, idleAfter: TimeInterval) -> LiveStatus? {
        let relevant = items.filter { ![.context, .note, .hook].contains($0.kind) }
        guard let last = relevant.last else { return nil }

        let promptIndex = relevant.lastIndex { $0.kind == .prompt && !$0.isSidechain }
        let turnItems = promptIndex.map { Array(relevant[$0...]) } ?? relevant
        let turnStart = promptIndex.map { relevant[$0].timestamp }
        let steps = Set(turnItems.compactMap(\.messageID)).count
        let toolsInTurn = turnItems.filter { $0.kind == .toolCall }.count
        let running = tools.filter {
            $0.isRunning && now.timeIntervalSince($0.start) < runningToolTimeout && $0.start >= (turnStart ?? .distantPast)
        }

        var state: LiveState
        var since = last.timestamp
        if let tool = running.max(by: { $0.start < $1.start }) {
            // Prefer the subagent call itself over the tools it runs, if one is open.
            if let agent = running.first(where: { $0.category == .agent && !$0.call.isSidechain }), agent.id != tool.id {
                state = .runningSubagent(title: agent.call.title + " → " + tool.call.title)
                since = agent.start
            } else if tool.category == .agent {
                state = .runningSubagent(title: tool.call.title)
                since = tool.start
            } else {
                state = .runningTool(name: tool.name, title: tool.call.title)
                since = tool.start
            }
        } else if now.timeIntervalSince(last.timestamp) > idleAfter {
            state = .idle
        } else {
            switch last.kind {
            case .prompt, .queued, .toolResult, .compact, .toolCall:
                state = .thinking
            case .thinking:
                state = .writing
            case .reply:
                if last.stopReason == "tool_use" || (last.stopReason == nil && now.timeIntervalSince(last.timestamp) < 120) {
                    state = .writing
                } else {
                    state = .waitingForUser
                }
            case .interrupted:
                state = .interrupted
            case .apiError:
                state = .error(last.title)
            default:
                state = .idle
            }
        }

        return LiveStatus(
            state: state,
            since: since,
            lastActivity: last.timestamp,
            turnStart: turnStart,
            stepsInTurn: steps,
            toolsInTurn: toolsInTurn,
            runningTools: running.count,
            sessionID: sessionID
        )
    }
}
