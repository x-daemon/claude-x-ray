#!/usr/bin/env python3
"""Generates synthetic Claude Code transcripts for demos, screenshots and manual testing.

Usage:
    python3 scripts/demo-data.py /tmp/xray-demo [--ago DAYS]
    CLAUDE_CONFIG_DIR=/tmp/xray-demo swift run S2AClaudeXRay

--ago DAYS moves everything DAYS into the past, as if Claude Code last ran then
(for the "no recent activity" screens).

Writes <dir>/projects/<project>/<session>.jsonl shaped like real transcripts:
one line per content block (with the usage repeated, as Claude Code does),
tool results, attachments (tools, MCP servers, skills, subagents, system prompt),
two weeks of history and a live session whose last tool call is still running.
Requests carry the API-level fields Claude Code records: stop reasons, cache diagnostics
(misses after pauses and after system prompt or tool changes), dropped thinking, iterations
of fallback answers, per-turn effort, thinking display and progress notes, the model's own
tool arguments (wireToolInputs), permission decisions and the sandbox flag.
All content is made up.
"""
import json
import os
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone

random.seed(7)
NOW = datetime.now(timezone.utc)


def iso(t):
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


class Session:
    def __init__(self, root, project_path, branch):
        self.id = str(uuid.uuid4())
        self.cwd = project_path
        self.branch = branch
        folder = os.path.join(root, "projects", project_path.replace("/", "-"))
        os.makedirs(folder, exist_ok=True)
        self.path = os.path.join(folder, self.id + ".jsonl")
        self.lines = []
        self.context = random.randint(18_000, 30_000)
        self.msg = 0

    def base(self, kind, t, sidechain=False):
        return {
            "type": kind, "uuid": str(uuid.uuid4()), "timestamp": iso(t), "sessionId": self.id,
            "cwd": self.cwd, "gitBranch": self.branch, "isSidechain": sidechain,
            "version": "2.1.325", "userType": "external",
        }

    def add(self, entry):
        self.lines.append(json.dumps(entry, ensure_ascii=False))

    def prompt(self, text, t):
        e = self.base("user", t)
        e["message"] = {"role": "user", "content": text}
        self.add(e)

    def attachment(self, payload, t):
        e = self.base("attachment", t)
        e["attachment"] = payload
        self.add(e)

    def usage(self, model, output, thinking, write1h=False, gap_rewrite=False, fast=False, search=0):
        growth = random.randint(800, 6_000)
        if gap_rewrite:
            write, read = self.context, 0
        else:
            write, read = growth, self.context
        self.context += growth + output
        return {
            "input_tokens": random.randint(1, 6), "output_tokens": output,
            "cache_read_input_tokens": read, "cache_creation_input_tokens": write,
            "cache_creation": {"ephemeral_5m_input_tokens": 0 if write1h else write, "ephemeral_1h_input_tokens": write if write1h else 0},
            "output_tokens_details": {"thinking_tokens": thinking},
            "server_tool_use": {"web_search_requests": search, "web_fetch_requests": 0},
            "service_tier": "standard", "speed": "fast" if fast else "standard", "inference_geo": "global",
        }

    def respond(self, t, blocks, model="claude-opus-5-5", effort="xhigh", stop="tool_use",
                thinking_ms=None, sidechain=False, gap_rewrite=False, fast=False, search=0, write1h=True,
                miss=None, dropped=None, requested=None, iterations=None, stop_details=None, advisor=None):
        """One API response written as one line per block, all sharing the usage.

        miss: cache-miss reason the API reports (the prefix is written to the cache again);
        dropped: reason a thinking block was dropped from the history;
        requested/iterations: a fallback model served the answer."""
        self.msg += 1
        message_id = f"msg_{uuid.uuid4().hex[:22]}"
        output = sum(b.get("_out", 200) for b in blocks)
        thinking = sum(b.get("_think", 0) for b in blocks)
        rewrite = gap_rewrite or (miss is not None and miss != "previous_message_not_found")
        prefix = self.context
        usage = self.usage(model, output + thinking, thinking, write1h=write1h, gap_rewrite=rewrite or gap_rewrite, fast=fast, search=search)
        if iterations:
            usage["iterations"] = iterations
        message_extra = {}
        if gap_rewrite and miss is None:
            miss = "previous_message_not_found"
        if miss:
            reason = {"type": miss}
            if miss != "previous_message_not_found":
                reason["cache_missed_input_tokens"] = prefix
            message_extra["diagnostics"] = {"cache_miss_reason": reason}
        if dropped:
            message_extra["input_transformations"] = [{"type": "thinking_dropped", "reason": dropped, "path": "messages.2.content.0"}]
        if stop_details:
            message_extra["stop_details"] = stop_details
        clock = t
        for block in blocks:
            note = block.get("_note")
            wire = block.get("_wire")
            block = {k: v for k, v in block.items() if not k.startswith("_")}
            if block["type"] == "thinking" and note:
                block["thinking"] = note
            e = self.base("assistant", clock, sidechain)
            e.update({
                "requestId": f"req_{message_id[4:]}", "effort": effort, "perTurnEffort": effort,
                "requestedModel": requested or model, "promptCacheRequested": "1h" if write1h else "5m",
            })
            if advisor:
                e["advisorModel"] = advisor
            e["message"] = {
                "id": message_id, "type": "message", "role": "assistant", "model": model,
                "content": [block], "stop_reason": stop, "stop_sequence": None, "usage": usage, **message_extra,
            }
            if block["type"] == "thinking":
                e["thinkingDisplay"] = "updates"
                if thinking_ms:
                    e["thinkingDurationMs"] = thinking_ms
            if block["type"] == "tool_use":
                e["toolInputStreamMs"] = random.randint(300, 4_000) if block["name"] not in ("Write", "Edit") else random.randint(3_000, 25_000)
                e["wireToolInputs"] = {block["id"]: wire if wire is not None else block["input"]}
            self.add(e)
            clock += timedelta(milliseconds=random.randint(200, 900))
        return clock

    def result(self, tool_id, content, t, error=False, patch=None, sidechain=False, extra=None):
        e = self.base("user", t, sidechain)
        block = {"type": "tool_result", "tool_use_id": tool_id, "content": content}
        if error:
            block["is_error"] = True
        e["message"] = {"role": "user", "content": [block]}
        e["sandboxed"] = random.random() < 0.3
        e["permissionDecision"] = random.choice([
            {"decision": "accept", "source": "config", "reasonType": "rule", "ruleSource": "localSettings"},
            {"decision": "accept", "source": "config", "reasonType": "classifier"},
        ])
        result = {"stdout": content if not error else "", "stderr": content if error else "", "interrupted": False}
        if patch:
            result = {"filePath": patch[0], "structuredPatch": [{"lines": patch[1]}]}
        if extra:
            result.update(extra)
        e["toolUseResult"] = result
        self.add(e)

    def save(self):
        with open(self.path, "w", encoding="utf-8") as f:
            f.write("\n".join(self.lines) + "\n")
        # The file was last written when its last entry was.
        stamps = [json.loads(line).get("timestamp") for line in self.lines]
        last = max(datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc) for s in stamps if s)
        os.utime(self.path, (last.timestamp(), last.timestamp()))


def tool(name, **inputs):
    return {"type": "tool_use", "id": f"toolu_{uuid.uuid4().hex[:22]}", "name": name, "input": inputs, "_out": random.randint(60, 400)}


def bash(cwd, command, description):
    """A Bash call whose model-generated command started with a `cd` that Claude Code dropped."""
    call = tool("Bash", command=command, description=description)
    if random.random() < 0.5:
        call["_wire"] = {"command": f"cd {cwd} && {command}", "description": description}
    return call


NOTES = [
    "Сначала посмотрю, где формируется отчёт, потом добавлю экспорт.",
    "Тест падает из-за нулевого числа страниц — проверю раскладку.",
    "Изменение небольшое: поправлю расчёт страниц и перезапущу тесты.",
    "Нужен список открытых задач, чтобы ничего не пропустить в PR.",
    "Поручу поиск вызовов субагенту, чтобы не раздувать контекст.",
]


def think(tokens=None, note=None):
    block = {"type": "thinking", "thinking": "", "signature": "demo", "_think": tokens or random.randint(150, 2_500), "_out": 0}
    if note:
        block["_note"] = note
    return block


def text(value):
    return {"type": "text", "text": value, "_out": random.randint(150, 900)}


def history(root):
    """Two weeks of finished sessions across three projects (so reports can compare weeks)."""
    projects = [
        ("/Users/demo/code/shop-api", "main", "claude-opus-5-5"),
        ("/Users/demo/code/ios-app", "feature/onboarding", "claude-sonnet-5-5"),
        ("/Users/demo/code/data-pipeline", "main", "claude-opus-5-5"),
    ]
    files = ["Sources/App/Router.swift", "Sources/App/Orders.swift", "Tests/AppTests/OrdersTests.swift", "README.md", "Package.swift"]
    for day in range(14, 0, -1):
        for _ in range(random.randint(2, 4)):
            path, branch, model = random.choice(projects)
            s = Session(root, path, branch)
            t = NOW - timedelta(days=day, hours=random.randint(0, 9), minutes=random.randint(0, 59))
            s.prompt(random.choice([
                "Почини падающий тест заказов", "Добавь пагинацию в список", "Отрефактори роутер",
                "Найди утечку памяти в загрузчике", "Обнови зависимости и проверь сборку",
            ]), t)
            for step in range(random.randint(8, 45)):
                t += timedelta(seconds=random.randint(4, 40))
                gap = random.random() < 0.06
                if gap:
                    t += timedelta(minutes=random.randint(70, 140))
                name = random.choice(["Read", "Read", "Bash", "Edit", "Grep", "Glob"])
                call = {
                    "Read": lambda: tool("Read", file_path=f"{path}/{random.choice(files)}"),
                    "Bash": lambda: bash(path, random.choice(["swift test", "swift build", "git status", "make lint"]), "Run checks"),
                    "Edit": lambda: tool("Edit", file_path=f"{path}/{random.choice(files)}", old_string="old", new_string="new"),
                    "Grep": lambda: tool("Grep", pattern=random.choice(["TODO", "func load", "Order("]), path=path),
                    "Glob": lambda: tool("Glob", pattern="**/*.swift"),
                }[name]()
                use_model = model if random.random() > 0.15 else "claude-haiku-5-5"
                sidechain = random.random() < 0.12
                roll = random.random()
                miss = "system_changed" if roll < 0.008 else "tools_changed" if roll < 0.014 else None
                dropped = "prefix_binding_mismatch" if step > 0 and ((miss and random.random() < 0.5) or random.random() < 0.004) else None
                end = s.respond(t, [think(), call], model=use_model, sidechain=sidechain, gap_rewrite=gap,
                                fast=random.random() < 0.02, search=1 if random.random() < 0.03 else 0,
                                miss=miss, dropped=dropped, advisor="claude-opus-5-5" if model == "claude-sonnet-5-5" else None)
                s.result(call["id"], "ok\n" + "x" * random.randint(100, 9_000), end + timedelta(seconds=random.uniform(0.3, 8)),
                         error=random.random() < 0.05, sidechain=sidechain)
            t += timedelta(seconds=20)
            if day == 9 and model == "claude-opus-5-5" and not getattr(history, "fallback_done", False):
                # A refused answer served by the fallback model.
                history.fallback_done = True
                fallback = [
                    {"type": "message", "model": model, "input_tokens": 4, "output_tokens": 0, "cache_read_input_tokens": s.context, "cache_creation_input_tokens": 0},
                    {"type": "fallback_message", "model": "claude-opus-4-8", "input_tokens": 6, "output_tokens": 420, "cache_read_input_tokens": 0, "cache_creation_input_tokens": s.context},
                ]
                s.respond(t, [text("Готово: проверка безопасности описана без примеров эксплойтов.")], model="claude-opus-4-8", requested=model,
                          stop="end_turn", iterations=fallback, miss="model_changed")
            elif random.random() < 0.1:
                s.respond(t, [think(), text("Готово: изменения внесены, но ответ обрезан — продолжу в следующем сообщении…")], model=model, stop="max_tokens")
            else:
                s.respond(t, [think(), text("Готово: изменения внесены, тесты проходят.")], model=model, stop="end_turn")
            s.save()


def live(root):
    """A session that is running right now."""
    s = Session(root, "/Users/demo/code/claude-x-ray", "feature/pdf-export")
    start = NOW - timedelta(minutes=27)
    s.attachment({"type": "environment", "snapshot": {
        "workingDirectory": s.cwd, "isWorktree": False, "isGitRepo": True, "additionalWorkingDirectories": [],
        "platform": "darwin", "shell": "zsh", "osVersion": "macOS 26.1"}}, start)
    s.attachment({"type": "model", "identity": {"modelId": "claude-opus-5-5", "marketingName": "Opus 5.5", "knowledgeCutoff": "June 2026"}}, start)
    tools = ["Read", "Write", "Edit", "Bash", "Grep", "Glob", "WebFetch", "WebSearch", "Task", "Skill", "TodoWrite",
             "mcp__github__get_file_contents", "mcp__github__list_issues", "mcp__github__create_pull_request",
             "mcp__github__list_pull_requests", "mcp__Linear__list_issues", "mcp__Linear__create_issue",
             "mcp__Slack__post_message", "mcp__Figma__get_file"]
    s.attachment({"type": "deferred_tools_delta", "addedNames": tools, "addedLines": tools, "removedNames": [],
                  "readdedNames": [], "pendingMcpServers": ["Figma"], "needsAuthMcpServers": ["Slack"], "failedMcpServers": ["Jira"]}, start)
    skills = ["dataviz", "pdf", "code-review", "simplify", "claude-api", "security-review", "docx"]
    s.attachment({"type": "skill_listing", "names": skills, "skillCount": len(skills), "isInitial": True, "content": "s" * 7_200}, start)
    s.attachment({"type": "mcp_instructions_delta", "addedNames": ["github", "Linear"], "addedBlocks": ["g" * 2_400, "l" * 1_600], "removedNames": []}, start)
    s.attachment({"type": "agent_listing_delta", "addedTypes": ["Explore", "Plan", "general-purpose"], "addedLines": ["a" * 140] * 3, "removedTypes": []}, start)
    s.attachment({"type": "prompt_snapshot", "systemPrompt": ["p" * 2_000] * 13}, start)
    s.attachment({"type": "auto_mode", "bashFirst": True, "steerOnly": True, "bypass": False}, start)
    s.attachment({"type": "command_permissions", "allowedTools": ["Bash(swift test:*)", "WebFetch(domain:developer.apple.com)"]}, start)

    t = start + timedelta(seconds=5)
    s.prompt("Добавь экспорт отчёта в PDF и покрой его тестами", t)
    t += timedelta(seconds=6)
    read1 = tool("Read", file_path=f"{s.cwd}/Sources/XRayCore/Export/ReportExporter.swift")
    grep = tool("Grep", pattern="markdown(", path=f"{s.cwd}/Sources")
    t = s.respond(t, [think(1_800, NOTES[0]), read1, grep], thinking_ms=4_200, miss="previous_message_not_found")
    s.result(read1["id"], "import Foundation\n" + "// exporter\n" * 300, t + timedelta(seconds=0.4))
    s.result(grep["id"], "Sources/XRayCore/Export/ReportExporter.swift:58: public static func markdown(", t + timedelta(seconds=0.9))
    t += timedelta(seconds=9)
    edit = tool("Edit", file_path=f"{s.cwd}/Sources/XRayCore/Export/ReportExporter.swift", old_string="// MARK: Markdown", new_string="// MARK: PDF\n...")
    t = s.respond(t, [think(2_400), edit], thinking_ms=6_900)
    s.result(edit["id"], "The file was updated", t + timedelta(seconds=0.3),
             patch=(edit["input"]["file_path"], [" // MARK", "-old", "+pdf()", "+render()", "+export()"]))
    t += timedelta(seconds=7)
    test1 = bash(s.cwd, "swift test --filter ReportExporterTests", "Run exporter tests")
    test1["_wire"] = {"command": f"cd {s.cwd} && swift test --filter ReportExporterTests", "description": "Run exporter tests"}
    t = s.respond(t, [test1])
    s.result(test1["id"], "error: testPDFHasPages failed: expected 3 pages, got 0\nExit code 1", t + timedelta(seconds=24), error=True)
    t += timedelta(seconds=31)
    edit2 = tool("Edit", file_path=f"{s.cwd}/Sources/XRayCore/Export/ReportExporter.swift", old_string="pages: 0", new_string="pages: layout.count")
    t = s.respond(t, [think(3_100, NOTES[1]), edit2], thinking_ms=11_400)
    s.result(edit2["id"], "The file was updated", t + timedelta(seconds=0.2),
             patch=(edit2["input"]["file_path"], ["-pages: 0", "+pages: layout.count"]))
    t += timedelta(seconds=5)
    test2 = bash(s.cwd, "swift test --filter ReportExporterTests", "Run exporter tests")
    t = s.respond(t, [test2])
    s.result(test2["id"], "Executed 6 tests, with 0 failures", t + timedelta(seconds=19))
    t += timedelta(seconds=26)
    s.respond(t, [text("PDF-экспорт добавлен, 6 тестов проходят. Отчёт содержит итоги, модели, проекты и рекомендации.")], stop="end_turn")
    s.add({**s.base("system", t + timedelta(seconds=1)), "subtype": "stop_hook_summary", "hookCount": 1,
           "hookErrors": [], "preventedContinuation": False, "level": "suggestion"})

    # Second turn, still running.
    t = NOW - timedelta(minutes=6)
    s.prompt("Проверь открытые issues, сделай code review и открой PR", t)
    t += timedelta(seconds=5)
    issues = tool("mcp__github__list_issues", repo="claude-x-ray", state="open")
    linear = tool("mcp__Linear__list_issues", query="PDF export")
    # Figma finished connecting between the turns: the tool list changed and the cache missed.
    t = s.respond(t, [think(1_200, NOTES[3]), issues, linear], thinking_ms=3_800, miss="tools_changed")
    s.result(issues["id"], "[#12 PDF export, #14 Dark mode chart colors]", t + timedelta(seconds=1.6))
    s.result(linear["id"], "XR-31 PDF export (In Progress)", t + timedelta(seconds=2.4))
    t += timedelta(seconds=8)
    skill = tool("Skill", skill="code-review")
    t = s.respond(t, [skill])
    s.result(skill["id"], "Launching skill: code-review", t + timedelta(seconds=0.5))
    t += timedelta(seconds=6)
    agent = tool("Task", description="Find callers of markdown()", subagent_type="Explore", prompt="Find all callers of ReportExporter.markdown and summarise")
    t = s.respond(t, [think(900, NOTES[4]), agent], thinking_ms=2_600)
    sub_start = t + timedelta(seconds=1)
    g = tool("Grep", pattern="ReportExporter.markdown", path=s.cwd)
    st = s.respond(sub_start, [g], model="claude-haiku-5-5", effort="low", sidechain=True, write1h=False)
    s.result(g["id"], "Views/ReportsView.swift:13\nTests/InsightAndExportTests.swift:61", st + timedelta(seconds=0.6), sidechain=True)
    r = tool("Read", file_path=f"{s.cwd}/Sources/S2AClaudeXRay/Views/ReportsView.swift")
    st = s.respond(st + timedelta(seconds=2), [r], model="claude-haiku-5-5", effort="low", sidechain=True, write1h=False)
    s.result(r["id"], "struct ReportsView: View {\n" + "  // ...\n" * 120, st + timedelta(seconds=0.3), sidechain=True)
    st = s.respond(st + timedelta(seconds=3), [text("2 вызова: ReportsView и тесты.")], model="claude-haiku-5-5", effort="low", stop="end_turn", sidechain=True, write1h=False)
    s.result(agent["id"], "2 callers: ReportsView.swift:13, InsightAndExportTests.swift:61", st + timedelta(seconds=0.5))
    s.add({"type": "queue-operation", "operation": "enqueue", "timestamp": iso(NOW - timedelta(minutes=2, seconds=40)),
           "sessionId": s.id, "content": "и обнови README"})
    t = st + timedelta(seconds=4)
    s.attachment({"type": "queued_command", "prompt": "и обнови README", "commandMode": "prompt", "origin": {"kind": "human"}, "humanTurn": True},
                 NOW - timedelta(minutes=2, seconds=20))
    t = max(t, NOW - timedelta(minutes=2, seconds=15))
    write = tool("Write", file_path=f"{s.cwd}/README.md", content="# S2A Claude X-Ray\n" + "line\n" * 140)
    # The queued message was added to the history mid-turn: the API dropped the earlier thinking.
    t = s.respond(t, [think(1_500), write], thinking_ms=5_100, dropped="prefix_binding_mismatch")
    s.result(write["id"], "File created successfully", t + timedelta(seconds=0.2), extra={"type": "update"})
    s.attachment({"type": "edited_text_file", "filename": f"{s.cwd}/Package.swift", "snippet": ""}, t + timedelta(seconds=3))
    t += timedelta(seconds=6)
    pr = tool("mcp__github__create_pull_request", repo="claude-x-ray", title="Add PDF export", head="feature/pdf-export", base="main")
    t = s.respond(t, [pr])
    s.result(pr["id"], "Created PR #15: Add PDF export", t + timedelta(seconds=2.1))
    t = max(t + timedelta(seconds=4), NOW - timedelta(seconds=40))
    build = tool("Bash", command="swift build -c release && ./scripts/build-app.sh", description="Release build")
    build["_wire"] = {"command": f"cd {s.cwd} && swift build -c release && ./scripts/build-app.sh", "description": "Release build"}
    s.respond(t, [think(700), build], thinking_ms=1_900)
    # No result yet: the release build is still running.
    s.save()


def main():
    global NOW
    args = sys.argv[1:]
    if "--ago" in args:
        i = args.index("--ago")
        NOW -= timedelta(days=float(args[i + 1]))
        del args[i:i + 2]
    if len(args) != 1:
        print(__doc__)
        sys.exit(1)
    root = args[0]
    os.makedirs(os.path.join(root, "projects"), exist_ok=True)
    history(root)
    live(root)
    count = sum(len(files) for _, _, files in os.walk(os.path.join(root, "projects")))
    print(f"demo transcripts: {count} files in {root}/projects")


if __name__ == "__main__":
    main()
