import XCTest
@testable import XRayCore

/// Request-level details: stop reasons, cache diagnostics, dropped thinking, tool arguments,
/// permission decisions, LLM calls and the insights built on them.
final class LLMCallTests: XCTestCase {
    private func usageLine(message: [String: Any] = [:], usage: [String: Any] = [:], entry: [String: Any] = [:]) -> Data {
        var object = try! JSONSerialization.jsonObject(with: Data(Fixture.assistantLine().utf8)) as! [String: Any]
        var msg = object["message"] as! [String: Any]
        var use = msg["usage"] as! [String: Any]
        for (key, value) in usage { use[key] = value }
        msg["usage"] = use
        for (key, value) in message { msg[key] = value }
        object["message"] = msg
        for (key, value) in entry { object[key] = value }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testRequestDetails() throws {
        let line = usageLine(
            message: [
                "stop_reason": "refusal",
                "stop_details": ["type": "refusal", "category": "cyber", "explanation": "…"],
                "diagnostics": ["cache_miss_reason": ["type": "system_changed", "cache_missed_input_tokens": 42_291]],
                "input_transformations": [["type": "thinking_dropped", "reason": "prefix_binding_mismatch", "path": "messages.2.content.0"]],
                "context_management": ["applied_edits": [["type": "clear_tool_uses_20250919", "cleared_input_tokens": 9_000, "cleared_tool_uses": 4]]],
            ],
            usage: [
                "inference_geo": "us",
                "iterations": [
                    ["type": "message", "input_tokens": 2, "output_tokens": 10, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 0],
                    ["type": "fallback_message", "model": "claude-opus-4-8", "input_tokens": 3, "output_tokens": 390, "cache_read_input_tokens": 0,
                     "cache_creation": ["ephemeral_5m_input_tokens": 50, "ephemeral_1h_input_tokens": 0]],
                ],
            ],
            entry: ["perTurnEffort": "max", "effort": "xhigh", "requestedModel": "claude-opus-5-5", "advisorModel": "claude-fable-5-2", "promptCacheRequested": "1h"]
        )
        let event = try XCTUnwrap(TranscriptParser.parse(line: line))
        XCTAssertEqual(event.effort, "max", "the per-turn effort wins over the session default")
        let d = try XCTUnwrap(event.details)
        XCTAssertEqual(d.stopReason, "refusal")
        XCTAssertEqual(d.stopCategory, "cyber")
        XCTAssertEqual(d.advisorModel, "claude-fable-5-2")
        XCTAssertEqual(d.inferenceGeo, "us")
        XCTAssertEqual(d.cacheTTL, "1h")
        XCTAssertEqual(d.cacheMiss, CacheMiss(reason: "system_changed", missedTokens: 42_291))
        XCTAssertEqual(d.droppedThinking, 1)
        XCTAssertEqual(d.transformations.first?.reason, "prefix_binding_mismatch")
        XCTAssertEqual(d.contextEdits, [ContextEdit(type: "clear_tool_uses_20250919", clearedTokens: 9_000, clearedToolUses: 4)])
        XCTAssertEqual(d.iterations.count, 2)
        XCTAssertEqual(d.iterations.last?.type, "fallback_message")
        XCTAssertEqual(d.iterations.last?.cacheWrite, 50)
        XCTAssertEqual(LLMCalls.stopReason("refusal", category: "cyber").title, "отказ: cyber")
        XCTAssertEqual(LLMCalls.stopReason("end_turn").tone, .good)

        // A single plain "message" iteration adds nothing and is not kept.
        let plain = try XCTUnwrap(TranscriptParser.parse(line: usageLine(
            message: ["stop_reason": "end_turn"],
            usage: ["iterations": [["type": "message", "input_tokens": 2, "output_tokens": 400]]]
        )))
        XCTAssertEqual(plain.details?.iterations, [])
        XCTAssertEqual(plain.details?.stopReason, "end_turn")
    }

    func testToolArgumentsPermissionsAndThinkingDisplay() throws {
        var assistant: [String: Any] = Act.base("assistant", 0, uuid: "a1")
        assistant["thinkingDurationMs"] = 1500
        assistant["thinkingDisplay"] = "updates"
        assistant["wireToolInputs"] = ["toolu_1": ["command": "cd /w && npm test", "description": "Run tests"]]
        assistant["message"] = [
            "id": "msg_1", "model": "claude-opus-5-5", "stop_reason": "tool_use",
            "content": [
                ["type": "thinking", "thinking": "Проверю тесты", "signature": "x"],
                ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "npm test", "description": "Run tests"]],
            ],
        ]
        let items = ActivityParser.parse(line: Data(Act.json(assistant).utf8))
        XCTAssertEqual(items.first { $0.kind == .thinking }?.thinkingDisplay, "updates")
        let call = try XCTUnwrap(items.first { $0.kind == .toolCall })
        XCTAssertTrue(call.rawInput?.contains("cd /w && npm test") ?? false, "the model's own arguments come from wireToolInputs")
        XCTAssertTrue(call.execInput?.contains("\"command\":\"npm test\"") ?? false, "what Claude Code ran is kept when it differs")

        let result = Act.userBlocks(
            [["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]], 5,
            extra: ["sandboxed": true, "permissionDecision": ["decision": "accept", "reasonType": "classifier", "source": "config"]]
        )
        let res = try XCTUnwrap(ActivityParser.parse(line: Data(result.utf8)).first)
        XCTAssertEqual(res.decision, "accept")
        XCTAssertEqual(res.decidedBy, "classifier")
        XCTAssertEqual(res.sandboxed, true)
        XCTAssertEqual(LLMCalls.decisionTitle(res), "разрешено: классификатор auto mode")

        // Same arguments: nothing extra is stored.
        assistant["wireToolInputs"] = ["toolu_1": ["command": "npm test", "description": "Run tests"]]
        let same = ActivityParser.parse(line: Data(Act.json(assistant).utf8)).first { $0.kind == .toolCall }
        XCTAssertNil(same?.execInput)
    }

    func testCallsIssuesAndInsights() throws {
        func usage(_ input: Int, _ output: Int, read: Int, write1h: Int) -> [String: Any] {
            ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": read, "cache_creation_input_tokens": write1h,
             "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": write1h]]
        }
        var first = Act.base("assistant", 4, uuid: "a1")
        first["requestId"] = "req_1"
        first["perTurnEffort"] = "high"
        first["message"] = [
            "id": "msg_1", "model": "claude-opus-5-5", "stop_reason": "tool_use",
            "diagnostics": ["cache_miss_reason": ["type": "tools_changed", "cache_missed_input_tokens": 30_000]],
            "content": [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "npm test"]]],
            "usage": usage(5, 120, read: 10_000, write1h: 30_000),
        ]
        var second = Act.base("assistant", 15, uuid: "a2")
        second["requestId"] = "req_2"
        second["message"] = [
            "id": "msg_2", "model": "claude-opus-5-5", "stop_reason": "end_turn",
            "input_transformations": [["type": "thinking_dropped", "reason": "prefix_binding_mismatch", "path": "messages.1.content.0"]],
            "content": [["type": "text", "text": "Готово"]],
            "usage": usage(3, 40, read: 40_000, write1h: 0),
        ]
        let lines = [
            Act.prompt("Почини тесты", 0),
            Act.json(first),
            Act.userBlocks([["type": "tool_result", "tool_use_id": "toolu_1", "content": "1 failed", "is_error": true]], 9),
            Act.json(second),
        ]
        let items = lines.flatMap { ActivityParser.parse(line: Data($0.utf8)) }
        let events = lines.compactMap { TranscriptParser.parse(line: Data($0.utf8)) }
        let pricing = PricingTable.default
        let priced = pricing.price(events)
        let byMessage = Dictionary(priced.map { ($0.event.messageID, $0) }, uniquingKeysWith: { first, _ in first })
        let trace = TraceBuilder.build(sessionID: "s1", items: items, now: Act.at(60))
        let calls = LLMCalls.build(trace: trace, usage: byMessage)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].index, 1)
        XCTAssertEqual(calls[0].tools.count, 1)
        XCTAssertTrue(calls[0].tools[0].isError)
        XCTAssertEqual(calls[0].turn, calls[1].turn, "both requests answer the same prompt")
        XCTAssertEqual(trace.turns[calls[0].turn].prompt?.title, "Почини тесты")
        XCTAssertEqual(calls[0].details.cacheMiss?.reason, "tools_changed")
        XCTAssertTrue(calls[0].hasIssue)
        XCTAssertEqual(calls[1].replies.first?.title, "Готово")
        XCTAssertTrue(calls[1].hasIssue)

        let issues = RequestIssues.of(priced, pricing: pricing)
        XCTAssertEqual(issues.realMisses, 1)
        XCTAssertEqual(issues.realMissedTokens, 30_000)
        // Opus 5.5: 1-hour write $8/MTok vs read $0.20/MTok -> 30K tokens * $7.80 / 1M.
        XCTAssertEqual(issues.realExtraCost, 0.234, accuracy: 1e-9)
        XCTAssertEqual(issues.droppedRequests, 1)
        XCTAssertEqual(issues.stopReasons["tool_use"], 1)

        let insights = InsightEngine(pricing: pricing).analyze(priced)
        let misses = try XCTUnwrap(insights.first { $0.id == "cache.misses" })
        XCTAssertTrue(misses.recommendation?.contains("MCP") ?? false)
        XCTAssertTrue(insights.contains { $0.id == "thinking.dropped" })
    }
}
