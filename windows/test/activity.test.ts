import { Act, assistantLine, at } from "./fixtures";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, appendFileSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { describeTool, itemProjectName, mcpServer, mcpTool, toolCategory, toolDisplayName, type ActivityItem } from "../src/core/activity";
import { candidateProjectDirectories, IncrementalLineReader, newestModification, TranscriptIngestor } from "../src/core/ingest";
import { ActivityStore, buildTrace, flowNodeID, stateIsActive, toolDuration, toolIsRunning, toolName } from "../src/core/trace";
import { UsageStore } from "../src/core/transcript";

test("user text kinds", () => {
  const items = Act.items([
    Act.prompt("Сделай MVP\nс графиками", 0),
    Act.prompt("Base directory for this skill: /tmp/x", 1, undefined, true),
    Act.userBlocks([{ type: "text", text: "[Request interrupted by user]" }], 2),
    Act.prompt("<command-name>/model</command-name>\n<command-args>sonnet</command-args>", 3),
  ]);
  assert.deepEqual(items.map((i) => i.kind), ["prompt", "interrupted", "prompt"]);
  assert.equal(items[0].title, "Сделай MVP …");
  assert.equal(items[0].detail, "Сделай MVP\nс графиками");
  assert.equal(items[2].title, "Команда /model sonnet");
  assert.equal(itemProjectName(items[0]), "app");
});

test("assistant blocks and tool results", () => {
  const items = Act.items([
    Act.thinking(5, "msg_1", 2128),
    Act.toolUse("toolu_1", "Bash", { command: "swift test\n--parallel", description: "Run tests" }, 6, "msg_1", 1014),
  ]);
  assert.equal(items[0].kind, "thinking");
  assert.equal(items[0].thinkingMs, 2128);
  assert.equal(items[0].effort, "xhigh");
  const call = items[1];
  assert.equal(call.kind, "toolCall");
  assert.equal(call.title, "Bash: swift test …");
  assert.equal(call.inputStreamMs, 1014);
  assert.ok(call.detail?.includes("$ swift test"));

  const result = Act.items([Act.toolResult("toolu_2", "The file was updated", 7, false, { structuredPatch: [{ lines: [" ctx", "-old", "+new", "+more"] }] })])[0];
  assert.equal(result.kind, "toolResult");
  assert.equal(result.linesAdded, 2);
  assert.equal(result.linesRemoved, 1);
  assert.equal(result.permission, "accept · правило (cliArg)");
  assert.equal(result.outputBytes, 20);
  const error = Act.items([Act.toolResult("toolu_3", [{ type: "text", text: "Exit code 1\nboom" }], 8, true)])[0];
  assert.ok(error.isError);
  assert.equal(error.title, "Exit code 1 …");
});

test("attachments become context updates; account data is never read", () => {
  const items = Act.items([
    Act.attachment({
      type: "deferred_tools_delta",
      addedNames: ["Read", "mcp__github__get_file", "mcp__github__list_prs", "mcp__Gmail__send"],
      addedLines: ["Read", "mcp__github__get_file", "mcp__github__list_prs", "mcp__Gmail__send"],
      removedNames: [], pendingMcpServers: [], needsAuthMcpServers: ["Gmail"], failedMcpServers: ["Jira"],
    }, 0),
    Act.attachment({ type: "skill_listing", names: ["dataviz", "pdf"], skillCount: 2, content: "x".repeat(400) }, 1),
    Act.attachment({ type: "mcp_instructions_delta", addedNames: ["github"], addedBlocks: ["use it well"], removedNames: [] }, 2),
    Act.attachment({ type: "agent_listing_delta", addedTypes: ["Explore", "Plan"], addedLines: ["a", "b"], removedTypes: [] }, 3),
    Act.attachment({ type: "prompt_snapshot", systemPrompt: ["y".repeat(8_000), "z"] }, 4),
    Act.attachment({ type: "model", identity: { modelId: "claude-opus-5-5", marketingName: "Opus 5.5", knowledgeCutoff: "June 2026" } }, 5),
    Act.attachment({ type: "session_context", context: { userEmail: "me@example.com" } }, 6),
    Act.attachment({ type: "credential_org", organizationUuid: "org" }, 7),
    Act.attachment({ type: "queued_command", prompt: "very detailed", commandMode: "prompt" }, 8),
  ]);
  assert.equal(items.length, 7);
  assert.ok(!items.some((i) => (i.detail ?? "").includes("me@example.com") || i.title.includes("me@example.com")));
  assert.ok(items[0].title.includes("MCP: Gmail, github"));
  assert.ok(items[0].isError);
  assert.equal(items[4].title, "Системный промпт: 8001 символов (≈2K токенов)");
  assert.equal(items[6].kind, "queued");
  assert.equal(items[6].title, "Передано модели: very detailed");
});

test("system, queue and synthetic entries", () => {
  const hook = { ...Act.base("system", 1, "h1"), subtype: "stop_hook_summary", hookCount: 2, hookErrors: ["oops"] };
  const compact = { ...Act.base("system", 2, "c1"), subtype: "compact_boundary", compactMetadata: { trigger: "auto", preTokens: 180_000 } };
  const queue = { type: "queue-operation", operation: "enqueue", timestamp: new Date(at(3)).toISOString(), sessionId: "s1", content: "also add flow" };
  const synthetic = Act.assistant({ type: "text", text: "API Error: 529 overloaded" }, 4, "msg_err", { stop: "stop_sequence", model: "<synthetic>" });
  const items = Act.items([Act.json(hook), Act.json(compact), Act.json(queue), synthetic]);
  assert.deepEqual(items.map((i) => i.kind), ["hook", "compact", "queued", "apiError"]);
  assert.equal(items[0].title, "Хуки Stop: 2, ошибок: 1");
  assert.equal(items[1].title, "Контекст сжат автоматически · было 180K токенов");
  assert.equal(items[2].title, "В очереди: also add flow");
  assert.ok(items[3].isError);
});

test("tool descriptions", () => {
  assert.equal(describeTool("Read", { file_path: "/a/b/c/Main.swift", offset: 10 }).title, "Read c/Main.swift (с строки 10)");
  const write = describeTool("Write", { file_path: "/a/b/c.txt", content: "1\n2\n3" });
  assert.equal(write.title, "Write b/c.txt · 3 строк");
  assert.equal(write.fileAction, "write");
  assert.equal(describeTool("Grep", { pattern: "TODO", path: "/x/y/Sources" }).title, "Grep «TODO» в y/Sources");
  const mcp = describeTool("mcp__github__get_file_contents", { repo: "claude-x-ray" });
  assert.equal(mcp.title, "MCP github · get_file_contents: claude-x-ray");
  assert.equal(mcp.target, "github");
  assert.equal(describeTool("Task", { description: "Find usages", subagent_type: "Explore" }).title, "Субагент (Explore): Find usages");
  assert.equal(toolCategory("mcp__Gmail__send"), "MCP");
  assert.equal(toolCategory("Edit"), "Изменение файлов");
  assert.equal(mcpServer("mcp__claude-code-remote__add_repo"), "claude-code-remote");
  assert.equal(mcpTool("mcp__claude-code-remote__add_repo"), "add_repo");
  assert.equal(toolDisplayName("mcp__Linear__list_issues"), "MCP Linear · list_issues");
  assert.equal(describeTool("Read", { file_path: "C:\\Users\\me\\app\\src\\main.ts" }).title, "Read src/main.ts");
});

const sampleLines = (): string[] => [
  Act.attachment({ type: "skill_listing", names: ["dataviz"], skillCount: 1, content: "dataviz: charts" }, 0),
  Act.attachment({ type: "deferred_tools_delta", addedNames: ["mcp__github__get_file", "mcp__github__list_prs"], addedLines: ["a", "b"], removedNames: [], pendingMcpServers: [], needsAuthMcpServers: [], failedMcpServers: ["Jira"] }, 0),
  Act.prompt("Почини тест", 1, "p1"),
  Act.thinking(5, "m1", 3000),
  Act.toolUse("t1", "Read", { file_path: "/Users/me/code/app/Tests/A.swift" }, 6, "m1"),
  Act.toolUse("t2", "Edit", { file_path: "/Users/me/code/app/Sources/A.swift", old_string: "a", new_string: "b" }, 7, "m1", 900),
  Act.toolResult("t1", "file contents", 8),
  Act.toolResult("t2", "updated", 9, false, { structuredPatch: [{ lines: ["-a", "+b", "+c"] }] }),
  Act.toolUse("t3", "mcp__github__get_file", { path: "README.md" }, 15, "m2"),
  Act.toolResult("t3", "readme", 16),
  Act.toolUse("t4", "Skill", { skill: "dataviz" }, 17, "m3"),
  Act.toolResult("t4", "loaded", 18),
  Act.reply("Готово, тест проходит.", 25, "m4"),
  Act.prompt("Запусти все тесты", 60, "p2"),
  Act.toolUse("t5", "Bash", { command: "swift test" }, 65, "m5"),
];

test("live state: running tool, then thinking, writing, waiting, idle", () => {
  const trace = buildTrace("s1", Act.items(sampleLines()), at(80));
  const status = trace.status!;
  assert.deepEqual(status.state, { type: "runningTool", name: "Bash", title: "Bash: swift test" });
  assert.equal(status.since, at(65));
  assert.equal(status.turnStart, at(60));
  assert.equal(status.toolsInTurn, 1);
  assert.equal(status.runningTools, 1);
  assert.ok(stateIsActive(status.state));

  const lines = sampleLines();
  lines.push(Act.toolResult("t5", "All tests passed", 90));
  assert.equal(buildTrace("s1", Act.items(lines), at(95)).status?.state.type, "thinking");
  lines.push(Act.thinking(100, "m6", 4000));
  assert.equal(buildTrace("s1", Act.items(lines), at(101)).status?.state.type, "writing");
  lines.push(Act.reply("Все тесты прошли.", 104, "m6"));
  const done = buildTrace("s1", Act.items(lines), at(110));
  assert.equal(done.status?.state.type, "waitingForUser");
  assert.equal(done.turns[done.turns.length - 1].outcome, "completed");
  assert.equal(buildTrace("s1", Act.items(lines), at(104 + 11 * 60)).status?.state.type, "idle");
});

test("tools, steps, turns and the flow tree", () => {
  const trace = buildTrace("s1", Act.items(sampleLines()), at(80));
  assert.equal(trace.tools.length, 5);
  assert.deepEqual(trace.tools.filter(toolIsRunning).map(toolName), ["Bash"]);
  const edit = trace.tools.find((t) => toolName(t) === "Edit")!;
  assert.equal(toolDuration(edit, at(80)), 2);
  assert.deepEqual(trace.steps.map((s) => s.messageID), ["m1", "m2", "m3", "m4", "m5"]);
  assert.equal(trace.steps[0].start, at(1));
  assert.equal(trace.steps[0].thinkingMs, 3000);
  assert.equal(trace.steps[0].inputStreamMs, 900);
  assert.equal(trace.steps[0].toolCallIDs.length, 2);
  assert.equal(trace.steps[1].start, at(9));
  assert.equal(trace.turns.length, 3);
  const turn = trace.turns[1];
  assert.equal(turn.prompt?.title, "Почини тест");
  assert.deepEqual(turn.stepIDs, ["m1", "m2", "m3", "m4"]);
  assert.equal(turn.toolCalls, 4);
  assert.equal(turn.outcome, "completed");
  const node = turn.nodes[0];
  assert.equal(node.type, "step");
  if (node.type === "step") {
    assert.equal(node.step.messageID, "m1");
    assert.equal(node.children.length, 3);
    const tool = node.children[1];
    assert.equal(tool.type, "tool");
    if (tool.type === "tool") assert.equal(tool.tool.result?.title, "file contents");
    assert.ok(flowNodeID(node).startsWith("step|m1|"));
  }
  assert.equal(trace.turns[2].outcome, "inProgress");
  assert.equal(trace.prompts, 2);
});

test("files, MCP, skills, context, permissions and transitions", () => {
  const trace = buildTrace("s1", Act.items(sampleLines()), at(80));
  const edited = trace.files.find((f) => f.path.endsWith("Sources/A.swift"))!;
  assert.equal(edited.edits, 1);
  assert.equal(edited.linesAdded, 2);
  assert.equal(edited.linesRemoved, 1);
  const github = trace.mcpServers.find((s) => s.name === "github")!;
  assert.equal(github.status, "connected");
  assert.equal(github.toolsAvailable, 2);
  assert.equal(github.calls, 1);
  assert.equal(github.tools.get_file, 1);
  assert.equal(trace.mcpServers.find((s) => s.name === "Jira")?.status, "failed");
  const skill = trace.skills.find((s) => s.name === "dataviz")!;
  assert.ok(skill.available);
  assert.equal(skill.invocations, 1);
  assert.deepEqual(trace.context.failedMCP, ["Jira"]);
  assert.equal(trace.permissions[0].label, "accept · правило (cliArg)");
  assert.equal(trace.permissions[0].count, 4);
  assert.equal(trace.toolStats.find((s) => s.name === "Bash")?.running, 1);
  const pairs = new Set(trace.transitions.map((t) => `${t.from} → ${t.to}`));
  for (const pair of ["Промпт → Модель", "Модель → Read", "Read → Edit", "Модель → MCP: github", "Модель → Скилл", "Модель → Ответ", "Ответ → Промпт"]) {
    assert.ok(pairs.has(pair), pair);
  }
});

test("a running subagent is the live state", () => {
  const trace = buildTrace("s1", Act.items([
    Act.prompt("Найди все вызовы", 0, "p"),
    Act.toolUse("ta", "Task", { description: "Find calls", subagent_type: "Explore", prompt: "..." }, 2, "mA"),
    Act.toolUse("tb", "Grep", { pattern: "foo" }, 4, "mB", undefined, true),
  ]), at(10));
  assert.deepEqual(trace.status?.state, { type: "runningSubagent", title: "Субагент (Explore): Find calls → Grep «foo»" });
  assert.equal(trace.status?.since, at(2));
  assert.equal(trace.subagents.find((s) => s.type === "Explore")?.running, 1);
});

test("activity store: de-duplication, retention, capacity, sessions", () => {
  const now = at(0);
  const make = (id: string, kind: ActivityItem["kind"], ts: number, session: string, path: string): ActivityItem =>
    ({ id, kind, timestamp: ts, sessionID: session, projectPath: path, isSidechain: false, title: id, isError: false });
  const store = new ActivityStore(3_600_000, 100);
  assert.equal(store.merge([make("old", "prompt", now - 7_200_000, "s0", "/p"), make("b", "toolCall", now - 30_000, "s2", "/p/two"), make("a", "prompt", now - 60_000, "s1", "/p/one")], now), 2);
  assert.equal(store.merge([make("a", "prompt", now - 60_000, "s1", "/p/one")], now), 0);
  assert.deepEqual(store.items.map((i) => i.id), ["a", "b"]);
  assert.deepEqual(store.sessions().map((s) => s.id), ["s2", "s1"]);
  store.prune(now + 3_600_000 - 45_000);
  assert.deepEqual(store.items.map((i) => i.id), ["b"]);
  const capped = new ActivityStore(86_400_000, 2);
  capped.merge([0, 1, 2].map((i) => make(`i${i}`, "note", at(i), "s", "/p")), at(10));
  assert.deepEqual(capped.items.map((i) => i.id), ["i1", "i2"]);
});

test("incremental reader and ingestor", async () => {
  const root = mkdtempSync(join(tmpdir(), "xray-"));
  const project = join(root, "-Users-me-code-app");
  mkdirSync(join(project, "session-a", "subagents"), { recursive: true });
  const file = join(project, "session-a.jsonl");
  writeFileSync(file, [assistantLine({ id: "m1", contentType: "thinking" }), assistantLine({ id: "m1", contentType: "tool_use" }), assistantLine({ id: "m2" })].join("\n") + "\n");
  writeFileSync(join(project, "notes.txt"), "ignored");
  const agent = join(project, "session-a", "subagents", "agent-1.jsonl");
  writeFileSync(agent, assistantLine({ id: "m9" }) + "\n");
  utimesSync(file, new Date(Date.UTC(2026, 10, 10, 9)), new Date(Date.UTC(2026, 10, 10, 9)));
  utimesSync(agent, new Date(Date.UTC(2026, 10, 12, 18, 40)), new Date(Date.UTC(2026, 10, 12, 18, 40)));

  const ingestor = new TranscriptIngestor();
  const first = await ingestor.scan([root, join(root, "missing")]);
  assert.equal(first.filesSeen, 2);
  assert.equal(new UsageStore(first.events).count, 3);
  assert.deepEqual(first.sources.map((s) => [s.exists, s.files]), [[true, 2], [false, 0]]);
  assert.equal(newestModification(first), Date.UTC(2026, 10, 12, 18, 40));
  assert.equal((await ingestor.scan([root])).events.length, 0);
  appendFileSync(file, assistantLine({ id: "m3" }) + "\n");
  assert.deepEqual((await ingestor.scan([root])).events.map((e) => e.messageID), ["m3"]);
  ingestor.reset();
  assert.equal(new UsageStore((await ingestor.scan([root])).events).count, 4);

  const reader = new IncrementalLineReader();
  const partial = join(root, "partial.jsonl");
  writeFileSync(partial, '{"a":1}\n{"b":');
  assert.deepEqual(await reader.readNewLines(partial), ['{"a":1}']);
  appendFileSync(partial, "2}");
  assert.deepEqual(await reader.readNewLines(partial), ['{"b":2}'], "a complete trailing line without a newline is read");
  writeFileSync(partial, '{"c":3}\n');
  assert.deepEqual(await reader.readNewLines(partial), ['{"c":3}'], "truncation restarts from the top");

  const dirs = candidateProjectDirectories({ CLAUDE_CONFIG_DIR: "/opt/claude, /Users/me/.claude" }, "/Users/me");
  assert.deepEqual(dirs.map((d) => d.replace(/\\/g, "/")), ["/opt/claude/projects", "/Users/me/.claude/projects", "/Users/me/.config/claude/projects"]);
});
