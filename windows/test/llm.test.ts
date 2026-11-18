// Request-level details: stop reasons, cache diagnostics, dropped thinking, tool arguments,
// permission decisions, LLM calls and the insights built on them.
import assert from "node:assert/strict";
import { test } from "node:test";
import { parseActivityLine } from "../src/core/activityParser";
import { analyzeInsights } from "../src/core/insights";
import { buildLLMCalls, callHasIssue, decisionTitle, droppedThinking, requestIssues, stopReasonInfo } from "../src/core/llm";
import { defaultPricing, priceEvents } from "../src/core/pricing";
import { buildTrace } from "../src/core/trace";
import { parseUsageLine } from "../src/core/transcript";
import { assistantLine, date, iso } from "./fixtures";

/** An assistant line with the API-level fields Claude Code records. */
function detailedLine(extra: { message?: Record<string, unknown>; usage?: Record<string, unknown>; entry?: Record<string, unknown> } = {}): string {
  const entry = JSON.parse(assistantLine()) as Record<string, any>;
  Object.assign(entry, extra.entry ?? {});
  Object.assign(entry.message, extra.message ?? {});
  Object.assign(entry.message.usage, extra.usage ?? {});
  return JSON.stringify(entry);
}

test("request details: stop reason, cache diagnosis, transformations, iterations", () => {
  const line = detailedLine({
    entry: { perTurnEffort: "max", effort: "xhigh", requestedModel: "claude-opus-5-5", advisorModel: "claude-fable-5-2", promptCacheRequested: "1h" },
    message: {
      stop_reason: "refusal",
      stop_details: { type: "refusal", category: "cyber", explanation: "…" },
      diagnostics: { cache_miss_reason: { type: "system_changed", cache_missed_input_tokens: 42_291 } },
      input_transformations: [{ type: "thinking_dropped", reason: "prefix_binding_mismatch", path: "messages.2.content.0" }],
      context_management: { applied_edits: [{ type: "clear_tool_uses_20250919", cleared_input_tokens: 9_000, cleared_tool_uses: 4 }] },
    },
    usage: {
      inference_geo: "us",
      iterations: [
        { type: "message", input_tokens: 2, output_tokens: 10, cache_read_input_tokens: 100, cache_creation_input_tokens: 0 },
        { type: "fallback_message", model: "claude-opus-4-8", input_tokens: 3, output_tokens: 390, cache_read_input_tokens: 0, cache_creation: { ephemeral_5m_input_tokens: 50, ephemeral_1h_input_tokens: 0 } },
      ],
    },
  });
  const event = parseUsageLine(line)!;
  assert.equal(event.effort, "max", "the per-turn effort wins over the session default");
  const d = event.details!;
  assert.equal(d.stopReason, "refusal");
  assert.equal(d.stopCategory, "cyber");
  assert.equal(d.advisorModel, "claude-fable-5-2");
  assert.equal(d.inferenceGeo, "us");
  assert.equal(d.cacheTTL, "1h");
  assert.deepEqual(d.cacheMiss, { reason: "system_changed", missedTokens: 42_291 });
  assert.equal(droppedThinking(d), 1);
  assert.equal(d.transformations![0].reason, "prefix_binding_mismatch");
  assert.deepEqual(d.contextEdits, [{ type: "clear_tool_uses_20250919", clearedTokens: 9_000, clearedToolUses: 4 }]);
  assert.equal(d.iterations!.length, 2);
  assert.equal(d.iterations![1].type, "fallback_message");
  assert.equal(d.iterations![1].cacheWrite, 50);
  assert.equal(stopReasonInfo("refusal", "cyber").title, "отказ: cyber");
  assert.equal(stopReasonInfo("end_turn").tone, "good");

  // A single plain "message" iteration adds nothing and is not kept.
  const plain = parseUsageLine(detailedLine({ message: { stop_reason: "end_turn" }, usage: { iterations: [{ type: "message", input_tokens: 2, output_tokens: 400 }] } }))!;
  assert.equal(plain.details?.iterations, undefined);
  assert.equal(plain.details?.stopReason, "end_turn");
});

test("tool arguments, permission decisions, sandbox and thinking display", () => {
  const assistant = JSON.stringify({
    type: "assistant", uuid: "a1", timestamp: iso(date(2026, 11, 14, 17, 0)), sessionId: "s", cwd: "/w",
    thinkingDurationMs: 1500, thinkingDisplay: "updates", toolInputStreamMs: 300,
    wireToolInputs: { toolu_1: { command: "cd /w && npm test", description: "Run tests" } },
    message: {
      id: "msg_1", model: "claude-opus-5-5", stop_reason: "tool_use",
      content: [
        { type: "thinking", thinking: "Проверю тесты", signature: "x" },
        { type: "tool_use", id: "toolu_1", name: "Bash", input: { command: "npm test", description: "Run tests" } },
      ],
    },
  });
  const items = parseActivityLine(assistant);
  const thinking = items.find((i) => i.kind === "thinking")!;
  assert.equal(thinking.thinkingDisplay, "updates");
  const call = items.find((i) => i.kind === "toolCall")!;
  assert.match(call.rawInput!, /cd \/w && npm test/, "the model's own arguments come from wireToolInputs");
  assert.match(call.execInput!, /"command":"npm test"/, "what Claude Code ran is kept when it differs");

  const result = JSON.stringify({
    type: "user", uuid: "u1", timestamp: iso(date(2026, 11, 14, 17, 0, 5)), sessionId: "s", cwd: "/w", sandboxed: true,
    permissionDecision: { decision: "accept", reasonType: "classifier", source: "config" },
    message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "ok" }] },
  });
  const res = parseActivityLine(result)[0];
  assert.equal(res.decision, "accept");
  assert.equal(res.decidedBy, "classifier");
  assert.equal(res.sandboxed, true);
  assert.equal(decisionTitle(res), "разрешено: классификатор auto mode");

  // Same arguments: nothing extra is stored.
  const same = JSON.parse(assistant);
  same.wireToolInputs.toolu_1 = { command: "npm test", description: "Run tests" };
  const sameCall = parseActivityLine(JSON.stringify(same)).find((i) => i.kind === "toolCall")!;
  assert.equal(sameCall.execInput, undefined);
});

test("LLM calls join steps, actions and usage; issues and insights", () => {
  const t0 = date(2026, 11, 14, 17, 0);
  const lines = [
    JSON.stringify({ type: "user", uuid: "p1", timestamp: iso(t0), sessionId: "s", cwd: "/w", message: { role: "user", content: "Почини тесты" } }),
    JSON.stringify({
      type: "assistant", uuid: "a1", timestamp: iso(t0 + 4000), sessionId: "s", cwd: "/w", requestId: "req_1", perTurnEffort: "high",
      message: {
        id: "msg_1", model: "claude-opus-5-5", stop_reason: "tool_use",
        diagnostics: { cache_miss_reason: { type: "tools_changed", cache_missed_input_tokens: 30_000 } },
        content: [{ type: "tool_use", id: "toolu_1", name: "Bash", input: { command: "npm test" } }],
        usage: { input_tokens: 5, output_tokens: 120, cache_read_input_tokens: 10_000, cache_creation_input_tokens: 30_000, cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 30_000 } },
      },
    }),
    JSON.stringify({ type: "user", uuid: "r1", timestamp: iso(t0 + 9000), sessionId: "s", cwd: "/w", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "1 failed", is_error: true }] } }),
    JSON.stringify({
      type: "assistant", uuid: "a2", timestamp: iso(t0 + 15_000), sessionId: "s", cwd: "/w", requestId: "req_2",
      message: {
        id: "msg_2", model: "claude-opus-5-5", stop_reason: "end_turn",
        input_transformations: [{ type: "thinking_dropped", reason: "prefix_binding_mismatch", path: "messages.1.content.0" }],
        content: [{ type: "text", text: "Готово" }],
        usage: { input_tokens: 3, output_tokens: 40, cache_read_input_tokens: 40_000, cache_creation_input_tokens: 0 },
      },
    }),
  ];
  const items = lines.flatMap((l) => parseActivityLine(l));
  const events = lines.map((l) => parseUsageLine(l)).filter((e) => !!e);
  const priced = priceEvents(defaultPricing(), events);
  const usage = new Map(priced.map((p) => [p.event.messageID, p]));
  const trace = buildTrace("s", items, t0 + 60_000);
  const calls = buildLLMCalls(trace, usage);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].index, 1);
  assert.equal(calls[0].tools.length, 1);
  assert.equal(calls[0].tools[0].result?.isError, true);
  assert.equal(calls[0].turn, calls[1].turn, "both requests answer the same prompt");
  assert.equal(trace.turns[calls[0].turn].prompt?.title, "Почини тесты");
  assert.equal(calls[0].priced?.event.details?.cacheMiss?.reason, "tools_changed");
  assert.ok(callHasIssue(calls[0]), "a cache miss with a cause and a failed tool");
  assert.equal(calls[1].replies[0].title, "Готово");
  assert.ok(callHasIssue(calls[1]), "dropped thinking");

  const issues = requestIssues(defaultPricing(), priced);
  assert.equal(issues.realMisses, 1);
  assert.equal(issues.realMissedTokens, 30_000);
  // Opus 5.5: 1-hour write $8/MTok vs read $0.20/MTok -> 30K tokens * $7.80 / 1M.
  assert.ok(Math.abs(issues.realExtraCost - 0.234) < 1e-9, `extra cost ${issues.realExtraCost}`);
  assert.equal(issues.droppedRequests, 1);
  assert.equal(issues.stopReasons.get("tool_use"), 1);

  const insights = analyzeInsights(defaultPricing(), priced);
  const misses = insights.find((i) => i.id === "cache.misses")!;
  assert.ok(misses, "cache-miss insight");
  assert.match(misses.recommendation!, /MCP/);
  assert.ok(insights.some((i) => i.id === "thinking.dropped"));
});
