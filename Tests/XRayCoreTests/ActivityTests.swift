import XCTest
@testable import XRayCore

/// Synthetic transcript lines for the activity trace, shaped like Claude Code's JSONL.
enum Act {
    static let t0 = Fixture.date(2026, 11, 14, 17, 0)

    static func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    static func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    static func base(_ type: String, _ seconds: Double, uuid: String, session: String = "s1", sidechain: Bool = false) -> [String: Any] {
        [
            "type": type,
            "uuid": uuid,
            "timestamp": Fixture.iso(at(seconds)),
            "sessionId": session,
            "cwd": "/Users/me/code/app",
            "gitBranch": "main",
            "isSidechain": sidechain,
        ]
    }

    static func prompt(_ text: String, _ seconds: Double, uuid: String = UUID().uuidString, meta: Bool = false) -> String {
        var entry = base("user", seconds, uuid: uuid)
        entry["message"] = ["role": "user", "content": text]
        if meta { entry["isMeta"] = true }
        return json(entry)
    }

    static func userBlocks(_ blocks: [[String: Any]], _ seconds: Double, uuid: String = UUID().uuidString, extra: [String: Any] = [:], sidechain: Bool = false) -> String {
        var entry = base("user", seconds, uuid: uuid, sidechain: sidechain)
        entry["message"] = ["role": "user", "content": blocks]
        for (key, value) in extra { entry[key] = value }
        return json(entry)
    }

    static func assistant(
        _ block: [String: Any], _ seconds: Double, msg: String, stop: String? = "tool_use",
        uuid: String = UUID().uuidString, extra: [String: Any] = [:], sidechain: Bool = false, model: String = "claude-opus-5-5"
    ) -> String {
        var entry = base("assistant", seconds, uuid: uuid, sidechain: sidechain)
        var message: [String: Any] = ["id": msg, "model": model, "role": "assistant", "content": [block]]
        if let stop {
            message["stop_reason"] = stop
        } else {
            message["stop_reason"] = NSNull()
        }
        entry["message"] = message
        entry["requestId"] = "req_" + msg
        entry["perTurnEffort"] = "xhigh"
        entry["requestedModel"] = "claude-opus-5-5"
        for (key, value) in extra { entry[key] = value }
        return json(entry)
    }

    static func thinking(_ seconds: Double, msg: String, ms: Int) -> String {
        assistant(["type": "thinking", "thinking": "", "signature": "sig"], seconds, msg: msg, extra: ["thinkingDurationMs": ms])
    }

    static func toolUse(_ id: String, _ name: String, _ input: [String: Any], _ seconds: Double, msg: String, streamMs: Int? = nil, sidechain: Bool = false) -> String {
        var extra: [String: Any] = [:]
        if let streamMs { extra["toolInputStreamMs"] = streamMs }
        return assistant(["type": "tool_use", "id": id, "name": name, "input": input], seconds, msg: msg, extra: extra, sidechain: sidechain)
    }

    static func toolResult(_ id: String, _ content: Any, _ seconds: Double, isError: Bool = false, result: [String: Any]? = nil, sidechain: Bool = false) -> String {
        var extra: [String: Any] = [
            "permissionDecision": ["decision": "accept", "source": "config", "reasonType": "rule", "ruleSource": "cliArg"],
        ]
        if let result { extra["toolUseResult"] = result }
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
        if isError { block["is_error"] = true }
        return userBlocks([block], seconds, extra: extra, sidechain: sidechain)
    }

    static func reply(_ text: String, _ seconds: Double, msg: String, stop: String? = "end_turn") -> String {
        assistant(["type": "text", "text": text], seconds, msg: msg, stop: stop)
    }

    static func attachment(_ payload: [String: Any], _ seconds: Double, uuid: String = UUID().uuidString) -> String {
        var entry = base("attachment", seconds, uuid: uuid)
        entry["attachment"] = payload
        return json(entry)
    }

    static func items(_ lines: [String]) -> [ActivityItem] {
        lines.flatMap { ActivityParser.parse(line: Data($0.utf8)) }
    }
}

final class ActivityParserTests: XCTestCase {
    func testUserTextKinds() {
        let items = Act.items([
            Act.prompt("Сделай MVP\nс графиками", 0),
            Act.prompt("Base directory for this skill: /tmp/x", 1, meta: true),
            Act.userBlocks([["type": "text", "text": "[Request interrupted by user]"]], 2),
            Act.prompt("<command-name>/model</command-name>\n<command-args>sonnet</command-args>", 3),
        ])
        XCTAssertEqual(items.map(\.kind), [.prompt, .interrupted, .prompt])
        XCTAssertEqual(items[0].title, "Сделай MVP …")
        XCTAssertEqual(items[0].detail, "Сделай MVP\nс графиками")
        XCTAssertEqual(items[2].title, "Команда /model sonnet")
        XCTAssertEqual(items[0].projectName, "app")
    }

    func testAssistantBlocks() throws {
        let items = Act.items([
            Act.thinking(5, msg: "msg_1", ms: 2128),
            Act.toolUse("toolu_1", "Bash", ["command": "swift test\n--parallel", "description": "Run tests"], 6, msg: "msg_1", streamMs: 1014),
        ])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].kind, .thinking)
        XCTAssertEqual(items[0].thinkingMs, 2128)
        XCTAssertEqual(items[0].effort, "xhigh")
        XCTAssertEqual(items[0].messageID, "msg_1")

        let call = items[1]
        XCTAssertEqual(call.kind, .toolCall)
        XCTAssertEqual(call.toolName, "Bash")
        XCTAssertEqual(call.toolUseID, "toolu_1")
        XCTAssertEqual(call.title, "Bash: swift test …")
        XCTAssertEqual(call.inputStreamMs, 1014)
        XCTAssertTrue(try XCTUnwrap(call.detail).contains("$ swift test"))
    }

    func testToolResultWithPatchAndPermission() throws {
        let patch: [String: Any] = [
            "filePath": "/Users/me/code/app/a.swift",
            "structuredPatch": [["lines": [" ctx", "-old", "+new", "+more"]]],
        ]
        let item = try XCTUnwrap(Act.items([Act.toolResult("toolu_2", "The file was updated", 7, result: patch)]).first)
        XCTAssertEqual(item.kind, .toolResult)
        XCTAssertEqual(item.toolUseID, "toolu_2")
        XCTAssertEqual(item.linesAdded, 2)
        XCTAssertEqual(item.linesRemoved, 1)
        XCTAssertEqual(item.permission, "accept · правило (cliArg)")
        XCTAssertEqual(item.outputBytes, "The file was updated".utf8.count)
        XCTAssertFalse(item.isError)

        let error = try XCTUnwrap(Act.items([Act.toolResult("toolu_3", [["type": "text", "text": "Exit code 1\nboom"]], 8, isError: true)]).first)
        XCTAssertTrue(error.isError)
        XCTAssertEqual(error.title, "Exit code 1 …")
    }

    func testAttachmentsBecomeContextUpdates() throws {
        let items = Act.items([
            Act.attachment([
                "type": "deferred_tools_delta",
                "addedNames": ["Read", "mcp__github__get_file", "mcp__github__list_prs", "mcp__Gmail__send"],
                "addedLines": ["Read", "mcp__github__get_file", "mcp__github__list_prs", "mcp__Gmail__send"],
                "removedNames": [], "pendingMcpServers": [], "needsAuthMcpServers": ["Gmail"], "failedMcpServers": ["Jira"],
            ], 0),
            Act.attachment(["type": "skill_listing", "names": ["dataviz", "pdf"], "skillCount": 2, "content": String(repeating: "x", count: 400)], 1),
            Act.attachment(["type": "mcp_instructions_delta", "addedNames": ["github"], "addedBlocks": ["use it well"], "removedNames": []], 2),
            Act.attachment(["type": "agent_listing_delta", "addedTypes": ["Explore", "Plan"], "addedLines": ["a", "b"], "removedTypes": []], 3),
            Act.attachment(["type": "prompt_snapshot", "systemPrompt": [String(repeating: "y", count: 8_000), "z"]], 4),
            Act.attachment(["type": "model", "identity": ["modelId": "claude-opus-5-5", "marketingName": "Opus 5.5", "knowledgeCutoff": "June 2026"]], 5),
            Act.attachment(["type": "session_context", "context": ["userEmail": "me@example.com"]], 6),
            Act.attachment(["type": "credential_org", "organizationUuid": "org"], 7),
            Act.attachment(["type": "queued_command", "prompt": "very detailed", "commandMode": "prompt"], 8),
        ])
        XCTAssertEqual(items.count, 7, "account data attachments are skipped")
        XCTAssertFalse(items.contains { ($0.detail ?? "").contains("me@example.com") || $0.title.contains("me@example.com") })
        XCTAssertTrue(items[0].title.contains("MCP: Gmail, github"))
        XCTAssertTrue(items[0].isError, "a failed MCP server is an error")
        XCTAssertEqual(items[4].title, "Системный промпт: 8001 символов (≈2K токенов)")
        XCTAssertEqual(items.last?.kind, .queued)
        XCTAssertEqual(items.last?.title, "Передано модели: very detailed")
    }

    func testSystemQueueAndSyntheticEntries() {
        var hook = Act.base("system", 1, uuid: "h1")
        hook["subtype"] = "stop_hook_summary"
        hook["hookCount"] = 2
        hook["hookErrors"] = ["oops"]
        var compact = Act.base("system", 2, uuid: "c1")
        compact["subtype"] = "compact_boundary"
        compact["compactMetadata"] = ["trigger": "auto", "preTokens": 180_000]
        let queue: [String: Any] = ["type": "queue-operation", "operation": "enqueue", "timestamp": Fixture.iso(Act.at(3)), "sessionId": "s1", "content": "also add flow"]
        let synthetic = Act.assistant(["type": "text", "text": "API Error: 529 overloaded"], 4, msg: "msg_err", stop: "stop_sequence", model: "<synthetic>")

        let items = Act.items([Act.json(hook), Act.json(compact), Act.json(queue), synthetic])
        XCTAssertEqual(items.map(\.kind), [.hook, .compact, .queued, .apiError])
        XCTAssertEqual(items[0].title, "Хуки Stop: 2, ошибок: 1")
        XCTAssertTrue(items[0].isError)
        XCTAssertEqual(items[1].title, "Контекст сжат автоматически · было 180K токенов")
        XCTAssertEqual(items[2].title, "В очереди: also add flow")
        XCTAssertTrue(items[3].isError)
    }

    func testToolDescriptions() {
        XCTAssertEqual(ToolDescriber.describe(name: "Read", input: ["file_path": "/a/b/c/Main.swift", "offset": 10]).title, "Read c/Main.swift (с строки 10)")
        let write = ToolDescriber.describe(name: "Write", input: ["file_path": "/a/b/c.txt", "content": "1\n2\n3"])
        XCTAssertEqual(write.title, "Write b/c.txt · 3 строк")
        XCTAssertEqual(write.fileAction, .write)
        XCTAssertEqual(ToolDescriber.describe(name: "Grep", input: ["pattern": "TODO", "path": "/x/y/Sources"]).title, "Grep «TODO» в y/Sources")
        let mcp = ToolDescriber.describe(name: "mcp__github__get_file_contents", input: ["repo": "claude-x-ray"])
        XCTAssertEqual(mcp.title, "MCP github · get_file_contents: claude-x-ray")
        XCTAssertEqual(mcp.target, "github")
        XCTAssertEqual(ToolDescriber.describe(name: "Task", input: ["description": "Find usages", "subagent_type": "Explore"]).title, "Субагент (Explore): Find usages")
        XCTAssertEqual(ToolDescriber.category(of: "mcp__Gmail__send"), .mcp)
        XCTAssertEqual(ToolDescriber.category(of: "Edit"), .write)
        XCTAssertEqual(ToolDescriber.mcpServer(of: "mcp__claude-code-remote__add_repo"), "claude-code-remote")
        XCTAssertEqual(ToolDescriber.mcpTool(of: "mcp__claude-code-remote__add_repo"), "add_repo")
        XCTAssertEqual(ToolDescriber.displayName(for: "mcp__Linear__list_issues"), "MCP Linear · list_issues")
        XCTAssertEqual(ToolDescriber.displayName(for: "Bash"), "Bash")
    }
}

final class TraceBuilderTests: XCTestCase {
    /// prompt -> thinking -> Read + Edit -> results -> reply (end_turn) -> second prompt -> Bash still running.
    func sampleLines() -> [String] {
        [
            Act.attachment(["type": "skill_listing", "names": ["dataviz"], "skillCount": 1, "content": "dataviz: charts"], 0),
            Act.attachment([
                "type": "deferred_tools_delta",
                "addedNames": ["mcp__github__get_file", "mcp__github__list_prs"], "addedLines": ["a", "b"],
                "removedNames": [], "pendingMcpServers": [], "needsAuthMcpServers": [], "failedMcpServers": ["Jira"],
            ], 0),
            Act.prompt("Почини тест", 1, uuid: "p1"),
            Act.thinking(5, msg: "m1", ms: 3000),
            Act.toolUse("t1", "Read", ["file_path": "/Users/me/code/app/Tests/A.swift"], 6, msg: "m1"),
            Act.toolUse("t2", "Edit", ["file_path": "/Users/me/code/app/Sources/A.swift", "old_string": "a", "new_string": "b"], 7, msg: "m1", streamMs: 900),
            Act.toolResult("t1", "file contents", 8),
            Act.toolResult("t2", "updated", 9, result: ["structuredPatch": [["lines": ["-a", "+b", "+c"]]]]),
            Act.toolUse("t3", "mcp__github__get_file", ["path": "README.md"], 15, msg: "m2"),
            Act.toolResult("t3", "readme", 16),
            Act.toolUse("t4", "Skill", ["skill": "dataviz"], 17, msg: "m3"),
            Act.toolResult("t4", "loaded", 18),
            Act.reply("Готово, тест проходит.", 25, msg: "m4", stop: "end_turn"),
            Act.prompt("Запусти все тесты", 60, uuid: "p2"),
            Act.toolUse("t5", "Bash", ["command": "swift test"], 65, msg: "m5"),
        ]
    }

    func build(now: Date) -> SessionTrace {
        TraceBuilder.build(sessionID: "s1", items: Act.items(sampleLines()), now: now)
    }

    func testRunningToolIsTheLiveState() throws {
        let trace = build(now: Act.at(80))
        let status = try XCTUnwrap(trace.status)
        XCTAssertEqual(status.state, .runningTool(name: "Bash", title: "Bash: swift test"))
        XCTAssertEqual(status.since, Act.at(65))
        XCTAssertEqual(status.elapsed(at: Act.at(80)), 15, accuracy: 0.001)
        XCTAssertEqual(status.turnStart, Act.at(60))
        XCTAssertEqual(status.toolsInTurn, 1)
        XCTAssertEqual(status.runningTools, 1)
        XCTAssertTrue(status.state.isActive)
    }

    func testStatesAfterResultsRepliesAndIdle() throws {
        var lines = sampleLines()
        lines.append(Act.toolResult("t5", "All tests passed", 90))
        var trace = TraceBuilder.build(sessionID: "s1", items: Act.items(lines), now: Act.at(95))
        XCTAssertEqual(trace.status?.state, .thinking)

        lines.append(Act.thinking(100, msg: "m6", ms: 4000))
        trace = TraceBuilder.build(sessionID: "s1", items: Act.items(lines), now: Act.at(101))
        XCTAssertEqual(trace.status?.state, .writing)

        lines.append(Act.reply("Все тесты прошли.", 104, msg: "m6", stop: "end_turn"))
        trace = TraceBuilder.build(sessionID: "s1", items: Act.items(lines), now: Act.at(110))
        XCTAssertEqual(trace.status?.state, .waitingForUser)
        XCTAssertEqual(trace.turns.last?.outcome, .completed)

        trace = TraceBuilder.build(sessionID: "s1", items: Act.items(lines), now: Act.at(104 + 11 * 60))
        XCTAssertEqual(trace.status?.state, .idle)
    }

    func testToolsStepsAndTurns() throws {
        let trace = build(now: Act.at(80))
        XCTAssertEqual(trace.tools.count, 5)
        XCTAssertEqual(trace.tools.filter(\.isRunning).map(\.name), ["Bash"])
        let edit = try XCTUnwrap(trace.tools.first { $0.name == "Edit" })
        XCTAssertEqual(edit.duration(now: Act.at(80)), 2, accuracy: 0.001)

        XCTAssertEqual(trace.steps.map(\.messageID), ["m1", "m2", "m3", "m4", "m5"])
        let first = trace.steps[0]
        XCTAssertEqual(first.start, Act.at(1), "the first step starts at the prompt")
        XCTAssertEqual(first.thinkingMs, 3000)
        XCTAssertEqual(first.inputStreamMs, 900)
        XCTAssertEqual(first.toolCallIDs.count, 2)
        XCTAssertEqual(trace.steps[1].start, Act.at(9), "the next step starts at the last tool result")

        XCTAssertEqual(trace.turns.count, 3, "context updates before the first prompt form turn 0")
        let turn = trace.turns[1]
        XCTAssertEqual(turn.prompt?.title, "Почини тест")
        XCTAssertEqual(turn.stepIDs, ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(turn.toolCalls, 4)
        XCTAssertEqual(turn.outcome, .completed)
        guard case let .step(step, children) = turn.nodes[0] else { return XCTFail("expected a step node") }
        XCTAssertEqual(step.messageID, "m1")
        XCTAssertEqual(children.count, 3, "thinking + two tool calls")
        if case let .tool(tool) = children[1] {
            XCTAssertEqual(tool.result?.title, "file contents")
        } else {
            XCTFail("expected a tool node")
        }
        XCTAssertEqual(trace.turns[2].outcome, .inProgress)
        XCTAssertEqual(trace.prompts, 2)
    }

    func testFilesMCPSkillsAndContext() throws {
        let trace = build(now: Act.at(80))

        let edited = try XCTUnwrap(trace.files.first { $0.path.hasSuffix("Sources/A.swift") })
        XCTAssertEqual(edited.edits, 1)
        XCTAssertEqual(edited.linesAdded, 2)
        XCTAssertEqual(edited.linesRemoved, 1)
        XCTAssertEqual(trace.files.first { $0.path.hasSuffix("Tests/A.swift") }?.reads, 1)

        let github = try XCTUnwrap(trace.mcpServers.first { $0.name == "github" })
        XCTAssertEqual(github.status, .connected)
        XCTAssertEqual(github.toolsAvailable, 2)
        XCTAssertEqual(github.calls, 1)
        XCTAssertEqual(github.tools["get_file"], 1)
        XCTAssertEqual(trace.mcpServers.first { $0.name == "Jira" }?.status, .failed)

        let skill = try XCTUnwrap(trace.skills.first { $0.name == "dataviz" })
        XCTAssertTrue(skill.available)
        XCTAssertEqual(skill.invocations, 1)

        XCTAssertEqual(trace.context.skills, ["dataviz"])
        XCTAssertEqual(trace.context.failedMCP, ["Jira"])
        XCTAssertEqual(trace.permissions.first?.label, "accept · правило (cliArg)")
        XCTAssertEqual(trace.permissions.first?.count, 4)

        let bash = try XCTUnwrap(trace.toolStats.first { $0.name == "Bash" })
        XCTAssertEqual(bash.running, 1)
    }

    func testFlowTransitions() {
        let trace = build(now: Act.at(80))
        let pairs = Set(trace.transitions.map(\.id))
        XCTAssertTrue(pairs.contains("Промпт → Модель"))
        XCTAssertTrue(pairs.contains("Модель → Read"))
        XCTAssertTrue(pairs.contains("Read → Edit"))
        XCTAssertTrue(pairs.contains("Модель → MCP: github"))
        XCTAssertTrue(pairs.contains("Модель → Скилл"))
        XCTAssertTrue(pairs.contains("Модель → Ответ"))
        XCTAssertTrue(pairs.contains("Ответ → Промпт"))
    }

    func testSubagentState() throws {
        let lines = [
            Act.prompt("Найди все вызовы", 0, uuid: "p"),
            Act.toolUse("ta", "Task", ["description": "Find calls", "subagent_type": "Explore", "prompt": "..."], 2, msg: "mA"),
            Act.toolUse("tb", "Grep", ["pattern": "foo"], 4, msg: "mB", sidechain: true),
        ]
        let trace = TraceBuilder.build(sessionID: "s1", items: Act.items(lines), now: Act.at(10))
        let status = try XCTUnwrap(trace.status)
        guard case let .runningSubagent(title) = status.state else { return XCTFail("expected a running subagent, got \(status.state)") }
        XCTAssertEqual(title, "Субагент (Explore): Find calls → Grep «foo»")
        XCTAssertEqual(status.since, Act.at(2))
        XCTAssertEqual(trace.subagents.first { $0.type == "Explore" }?.running, 1)
    }
}

final class ActivityStoreTests: XCTestCase {
    func testDeduplicatesPrunesAndListsSessions() {
        let now = Act.at(0)
        var store = ActivityStore(retention: 3600, capacity: 100)
        let old = ActivityItem(id: "old", kind: .prompt, timestamp: now.addingTimeInterval(-7200), sessionID: "s0", projectPath: "/p", title: "old")
        let a = ActivityItem(id: "a", kind: .prompt, timestamp: now.addingTimeInterval(-60), sessionID: "s1", projectPath: "/p/one", title: "a")
        let b = ActivityItem(id: "b", kind: .toolCall, timestamp: now.addingTimeInterval(-30), sessionID: "s2", projectPath: "/p/two", title: "b")
        XCTAssertEqual(store.merge([old, b, a], now: now), 2, "items past retention are not stored")
        XCTAssertEqual(store.merge([a], now: now), 0)
        XCTAssertEqual(store.items.map(\.id), ["a", "b"])
        XCTAssertEqual(store.sessions().map(\.id), ["s2", "s1"])
        XCTAssertEqual(store.sessions().first?.toolCalls, 1)

        store.prune(now: now.addingTimeInterval(3600 - 45))
        XCTAssertEqual(store.items.map(\.id), ["b"])
    }

    func testCapacityDropsOldest() {
        var store = ActivityStore(retention: 86_400, capacity: 2)
        let items = (0..<3).map {
            ActivityItem(id: "i\($0)", kind: .note, timestamp: Act.at(Double($0)), sessionID: "s", projectPath: "/p", title: "\($0)")
        }
        store.merge(items, now: Act.at(10))
        XCTAssertEqual(store.items.map(\.id), ["i1", "i2"])
    }
}
