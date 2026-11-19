// Reconstructs activity (prompts, thinking, tool calls and results, context updates, hooks...) from
// transcript lines. Port of XRayCore/Activity/ActivityParser.swift. Lenient: unknown entry and block
// types are skipped. Entries that carry personal account data (session_context, credential_org)
// are never read.
import { describeTool, mcpServer, Snippet, type ActivityItem, type ActivityKind } from "./activity";
import { Fmt } from "./fmt";
import { parseDate } from "./transcript";
import { L } from "./i18n";

export const DETAIL_LIMIT = 2_000;
/** Tool arguments are kept up to this many characters (file contents are in `detail` already). */
export const INPUT_LIMIT = 1_200;

type Json = Record<string, unknown>;
const obj = (v: unknown): Json | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : undefined);
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
const int = (v: unknown): number | undefined => (typeof v === "number" && Number.isInteger(v) ? v : undefined);
const blocksOf = (v: unknown): Json[] | undefined => (Array.isArray(v) ? (v.filter((b) => obj(b)) as Json[]) : undefined);

interface Base {
  uuid: string;
  timestamp: number;
  sessionID: string;
  projectPath: string;
  gitBranch?: string;
  isSidechain: boolean;
}

function item(base: Base, index: number, kind: ActivityKind, title: string, detail?: string, isError = false): ActivityItem {
  return {
    id: `${base.uuid}#${index}`,
    kind,
    timestamp: base.timestamp,
    sessionID: base.sessionID,
    projectPath: base.projectPath,
    gitBranch: base.gitBranch,
    isSidechain: base.isSidechain,
    title,
    detail,
    isError,
  };
}

export function parseActivityLine(line: string, fallbackSessionID = "unknown", fallbackProject = "unknown"): ActivityItem[] {
  let entry: Json | undefined;
  try {
    entry = obj(JSON.parse(line));
  } catch {
    return [];
  }
  const type = str(entry?.type);
  const timestampString = str(entry?.timestamp);
  const timestamp = parseDate(timestampString);
  if (!entry || !type || !timestampString || timestamp === undefined) return [];
  const branch = str(entry.gitBranch);
  const base: Base = {
    uuid: str(entry.uuid) ?? `${type}|${timestampString}`,
    timestamp,
    sessionID: str(entry.sessionId) ?? fallbackSessionID,
    projectPath: str(entry.cwd) ?? fallbackProject,
    gitBranch: branch ? branch : undefined,
    isSidechain: entry.isSidechain === true,
  };
  switch (type) {
    case "user": return parseUser(entry, base);
    case "assistant": return parseAssistant(entry, base);
    case "attachment": return parseAttachment(entry, base);
    case "system": return parseSystem(entry, base);
    case "queue-operation": return parseQueue(entry, base, timestampString);
    default: return [];
  }
}

function parseUser(entry: Json, base: Base): ActivityItem[] {
  const message = obj(entry.message);
  if (!message) return [];
  const isMeta = entry.isMeta === true;
  if (entry.isCompactSummary === true) {
    return [item(base, 0, "compact", L`Сводка после сжатия контекста`, Snippet.truncate(textContent(message.content), DETAIL_LIMIT))];
  }
  const text = str(message.content);
  if (text !== undefined) {
    if (isMeta) return [];
    const one = userText(text, base, 0);
    return one ? [one] : [];
  }
  const blocks = blocksOf(message.content);
  if (!blocks) return [];
  const items: ActivityItem[] = [];
  blocks.forEach((block, index) => {
    switch (str(block.type) ?? "") {
      case "text": {
        const t = str(block.text);
        if (isMeta || t === undefined) return;
        const one = userText(t, base, index);
        if (one) items.push(one);
        return;
      }
      case "image":
        if (!isMeta) items.push(item(base, index, "prompt", L`Изображение`));
        return;
      case "tool_result":
        items.push(toolResult(block, entry, base, index));
        return;
    }
  });
  return items;
}

/** Classifies user text: interruption, slash command, command output or a plain prompt. */
function userText(text: string, base: Base, index: number): ActivityItem | undefined {
  const trimmed = text.trim();
  if (!trimmed) return undefined;
  if (trimmed.startsWith("[Request interrupted")) return item(base, index, "interrupted", L`Прервано пользователем`, trimmed);
  const name = tag("command-name", trimmed);
  if (name !== undefined) {
    const args = tag("command-args", trimmed) ?? "";
    return item(base, index, "prompt", L`Команда ${name} ${args}`.trim(), args || undefined);
  }
  const output = tag("local-command-stdout", trimmed);
  if (output !== undefined) return item(base, index, "note", L`Вывод команды: ` + Snippet.firstLine(output, 100), Snippet.truncate(output, DETAIL_LIMIT));
  const command = tag("bash-input", trimmed);
  if (command !== undefined) return item(base, index, "prompt", "! " + Snippet.firstLine(command, 100), command);
  if (trimmed.startsWith("<bash-stdout>") || trimmed.startsWith("<bash-stderr>")) {
    const out = tag("bash-stdout", trimmed) ?? tag("bash-stderr", trimmed) ?? "";
    return item(base, index, "note", L`Вывод оболочки: ` + Snippet.firstLine(out, 100), Snippet.truncate(out, DETAIL_LIMIT));
  }
  return item(base, index, "prompt", Snippet.firstLine(trimmed, 160), Snippet.truncate(trimmed, DETAIL_LIMIT));
}

function toolResult(block: Json, entry: Json, base: Base, index: number): ActivityItem {
  const text = textContent(block.content);
  const images = imageCount(block.content);
  const isError = block.is_error === true;
  const result = obj(entry.toolUseResult);
  let title = text ? Snippet.firstLine(text, 140) : images > 0 ? L`Изображение` : L`Пустой результат`;
  if (result?.interrupted === true) title = L`Прервано: ` + title;
  let detail = Snippet.truncate(text, DETAIL_LIMIT);
  const stderr = str(result?.stderr);
  if (stderr && !text.includes(stderr.slice(0, 80))) detail += "\n[stderr] " + Snippet.truncate(stderr, 600);
  const it = item(base, index, "toolResult", title, detail || undefined, isError);
  it.toolUseID = str(block.tool_use_id);
  it.outputBytes = new TextEncoder().encode(text).length;
  it.permission = permissionLabel(entry.permissionDecision);
  const decision = obj(entry.permissionDecision);
  if (decision) {
    it.decision = str(decision.decision);
    it.decidedBy = str(decision.reasonType) ?? str(decision.source);
    it.ruleSource = str(decision.ruleSource);
  }
  if (typeof entry.sandboxed === "boolean") it.sandboxed = entry.sandboxed;
  const patch = Array.isArray(result?.structuredPatch) ? (result!.structuredPatch as unknown[]) : undefined;
  if (patch) {
    let added = 0;
    let removed = 0;
    for (const hunk of patch) {
      const lines = Array.isArray(obj(hunk)?.lines) ? (obj(hunk)!.lines as unknown[]) : [];
      for (const l of lines) {
        if (typeof l !== "string") continue;
        if (l.startsWith("+")) added++;
        else if (l.startsWith("-")) removed++;
      }
    }
    it.linesAdded = added;
    it.linesRemoved = removed;
  }
  if (str(result?.type) === "create" && it.linesAdded === undefined) {
    const content = str(result?.content);
    if (content !== undefined) it.linesAdded = content.split("\n").length;
  }
  return it;
}

function parseAssistant(entry: Json, base: Base): ActivityItem[] {
  const message = obj(entry.message);
  const blocks = blocksOf(message?.content);
  if (!message || !blocks) return [];
  const model = str(message.model);
  const messageID = str(message.id);
  const stopReason = str(message.stop_reason);
  if (model === "<synthetic>") {
    const text = blocks.map((b) => str(b.text)).filter(Boolean).join("\n");
    return text ? [item(base, 0, "apiError", Snippet.firstLine(text, 160), Snippet.truncate(text, DETAIL_LIMIT), true)] : [];
  }
  const items: ActivityItem[] = [];
  blocks.forEach((block, index) => {
    const blockType = str(block.type) ?? "";
    let it: ActivityItem;
    if (blockType === "thinking" || blockType === "redacted_thinking") {
      const text = str(block.thinking) ?? "";
      it = item(base, index, "thinking", text ? Snippet.firstLine(text, 140) : L`Размышление`, text ? Snippet.truncate(text, DETAIL_LIMIT) : undefined);
      it.thinkingMs = int(entry.thinkingDurationMs);
      it.thinkingDisplay = str(entry.thinkingDisplay) ?? (blockType === "redacted_thinking" ? "redacted" : undefined);
    } else if (blockType === "text") {
      const text = str(block.text) ?? "";
      if (!text.trim()) return;
      it = item(base, index, "reply", Snippet.firstLine(text, 160), Snippet.truncate(text, DETAIL_LIMIT));
    } else if (blockType === "tool_use" || blockType === "server_tool_use") {
      const name = str(block.name) ?? "tool";
      const description = describeTool(name, obj(block.input) ?? {});
      it = item(base, index, "toolCall", description.title, description.detail);
      it.toolUseID = str(block.id);
      it.toolName = name;
      it.target = description.target;
      it.fileAction = description.fileAction;
      it.inputStreamMs = int(entry.toolInputStreamMs);
      // wireToolInputs holds the arguments as the model generated them; the block holds what ran.
      const executed = block.input ?? {};
      const wire = it.toolUseID ? obj(entry.wireToolInputs)?.[it.toolUseID] : undefined;
      it.rawInput = Snippet.compactJSON(wire ?? executed, INPUT_LIMIT);
      if (wire !== undefined) {
        const ran = Snippet.compactJSON(executed, INPUT_LIMIT);
        if (ran !== it.rawInput) it.execInput = ran;
      }
    } else if (blockType.endsWith("_tool_result")) {
      const text = textContent(block.content);
      it = item(base, index, "toolResult", text ? Snippet.firstLine(text, 140) : blockType, text ? Snippet.truncate(text, DETAIL_LIMIT) : undefined);
      it.toolUseID = str(block.tool_use_id);
      it.outputBytes = new TextEncoder().encode(text).length;
    } else {
      return;
    }
    it.messageID = messageID;
    it.model = model;
    it.requestedModel = str(entry.requestedModel);
    it.stopReason = stopReason;
    it.effort = str(entry.perTurnEffort) ?? str(entry.effort);
    it.attributionSkill = str(entry.attributionSkill);
    items.push(it);
  });
  return items;
}

function parseAttachment(entry: Json, base: Base): ActivityItem[] {
  const attachment = obj(entry.attachment);
  const type = str(attachment?.type);
  if (!attachment || !type) return [];
  const strings = (key: string): string[] => (Array.isArray(attachment[key]) ? (attachment[key] as unknown[]).filter((v): v is string => typeof v === "string") : []);
  const chars = (key: string): number => {
    const v = attachment[key];
    if (typeof v === "string") return v.length;
    return strings(key).reduce((s, t) => s + t.length, 0);
  };
  let it: ActivityItem;
  switch (type) {
    case "deferred_tools_delta": {
      const added = strings("addedNames");
      const removed = strings("removedNames");
      const pending = strings("pendingMcpServers");
      const failed = strings("failedMcpServers");
      const needsAuth = strings("needsAuthMcpServers");
      const servers = [...new Set(added.map(mcpServer).filter((s): s is string => !!s))].sort();
      let title = L`Инструменты: +${added.length}`;
      if (removed.length) title += ` −${removed.length}`;
      if (servers.length) title += ` · MCP: ${servers.join(", ")}`;
      const notes: string[] = [];
      if (failed.length) notes.push(L`Не подключились: ${failed.join(", ")}`);
      if (needsAuth.length) notes.push(L`Нужна авторизация: ${needsAuth.join(", ")}`);
      if (pending.length) notes.push(L`Подключаются: ${pending.join(", ")}`);
      it = item(base, 0, "context", title, notes.length ? notes.join("\n") : undefined, failed.length > 0);
      it.context = { type: "tools", added, removed, pendingMCP: pending, failedMCP: failed, needsAuthMCP: needsAuth, listingChars: chars("addedLines") };
      break;
    }
    case "skill_listing": {
      const names = strings("names");
      const count = int(attachment.skillCount) ?? names.length;
      it = item(base, 0, "context", L`Скиллы в контексте: ${count}`, names.join(", "));
      it.context = { type: "skills", names, count, listingChars: chars("content") };
      break;
    }
    case "mcp_instructions_delta": {
      const added = strings("addedNames");
      it = item(base, 0, "context", L`Инструкции MCP: ${added.join(", ")}`);
      it.context = { type: "mcpInstructions", added, removed: strings("removedNames"), chars: chars("addedBlocks") };
      break;
    }
    case "agent_listing_delta": {
      const added = strings("addedTypes");
      it = item(base, 0, "context", L`Типы субагентов: ${added.join(", ")}`);
      it.context = { type: "agents", added, removed: strings("removedTypes"), chars: chars("addedLines") };
      break;
    }
    case "prompt_snapshot": {
      const parts = strings("systemPrompt");
      const total = parts.length ? parts.reduce((s, p) => s + p.length, 0) : chars("systemPrompt");
      it = item(base, 0, "context", L`Системный промпт: ${total} символов (≈${Fmt.tokens(Math.floor(total / 4))} токенов)`);
      it.context = { type: "systemPrompt", chars: total, parts: Math.max(parts.length, 1) };
      break;
    }
    case "environment": {
      const snapshot = obj(attachment.snapshot) ?? {};
      const values: Record<string, string> = {};
      for (const [key, value] of Object.entries(snapshot)) {
        if (typeof value === "string") values[key] = value;
        else if (typeof value === "boolean") values[key] = value ? L`да` : L`нет`;
        else if (typeof value === "number") values[key] = String(value);
        else if (Array.isArray(value)) values[key] = value.filter((v): v is string => typeof v === "string").join(", ");
      }
      const summary = [values.platform, values.shell, values.osVersion].filter(Boolean).join(" · ");
      it = item(base, 0, "context", L`Окружение: ${summary}`, values.workingDirectory);
      it.context = { type: "environment", values };
      break;
    }
    case "model": {
      const identity = obj(attachment.identity) ?? {};
      const id = str(identity.modelId) ?? "?";
      const name = str(identity.marketingName);
      it = item(base, 0, "context", L`Модель: ${name ?? id}`, id);
      it.context = { type: "model", id, name, knowledgeCutoff: str(identity.knowledgeCutoff) };
      break;
    }
    case "auto_mode": {
      const flags: Record<string, string> = {};
      for (const [key, value] of Object.entries(attachment)) {
        if (key === "type") continue;
        if (typeof value === "boolean") flags[key] = value ? L`да` : L`нет`;
        else if (typeof value === "string") flags[key] = value;
      }
      it = item(base, 0, "context", L`Auto mode включён`);
      it.context = { type: "autoMode", values: flags };
      break;
    }
    case "command_permissions": {
      const allowed = strings("allowedTools");
      it = item(base, 0, "context", L`Разрешённые правила: ${allowed.length}`, allowed.join("\n"));
      it.context = { type: "permissions", allowed };
      break;
    }
    case "edited_text_file": {
      const path = str(attachment.filename) ?? "?";
      it = item(base, 0, "context", L`Файл изменён вне Claude: ${Snippet.shortPath(path)}`, path);
      it.context = { type: "editedFile", path };
      break;
    }
    case "task_reminder": {
      const count = int(attachment.itemCount) ?? 0;
      it = item(base, 0, "context", L`Список задач: ${count}`);
      it.context = { type: "tasks", count };
      break;
    }
    case "remote_session_change": {
      const commit = str(attachment.commit);
      const pr = str(attachment.pr);
      const url = str(attachment.url);
      const kinds = [commit ? L`коммит` : undefined, pr ? "PR" : undefined].filter(Boolean);
      it = item(base, 0, "context", L`Изменения сессии: ` + (kinds.length ? kinds.join(", ") : L`ссылка`), [commit, pr, url].filter(Boolean).join("\n"));
      it.context = { type: "remoteChange", commit, pullRequest: pr, url };
      break;
    }
    case "queued_command": {
      const prompt = str(attachment.prompt) ?? "";
      it = item(base, 0, "queued", L`Передано модели: ` + Snippet.firstLine(prompt, 140), Snippet.truncate(prompt, DETAIL_LIMIT));
      break;
    }
    default: {
      if (type.startsWith("hook")) {
        const name = str(attachment.hookName) ?? type;
        const content = str(attachment.content) ?? str(attachment.stdout);
        it = item(base, 0, "hook", L`Хук: ${name}`, content !== undefined ? Snippet.truncate(content, DETAIL_LIMIT) : undefined, type.includes("error"));
        break;
      }
      // date, silent reminders, deferred tool records; session_context and credential_org hold account data.
      return [];
    }
  }
  return [it];
}

function parseSystem(entry: Json, base: Base): ActivityItem[] {
  const subtype = str(entry.subtype) ?? "";
  if (subtype === "stop_hook_summary") {
    const count = int(entry.hookCount) ?? 0;
    const errors = Array.isArray(entry.hookErrors) ? entry.hookErrors.length : 0;
    let title = L`Хуки Stop: ${count}`;
    if (errors > 0) title += L`, ошибок: ${errors}`;
    if (entry.preventedContinuation === true) title += L` · остановили продолжение`;
    return [item(base, 0, "hook", title, undefined, errors > 0)];
  }
  if (subtype.includes("compact")) {
    const metadata = obj(entry.compactMetadata);
    const trigger = str(metadata?.trigger);
    const triggerText = trigger === undefined ? "" : trigger === "auto" ? L`автоматически` : L`вручную`;
    const preTokens = int(metadata?.preTokens);
    const pre = preTokens !== undefined ? L` · было ${Fmt.tokens(preTokens)} токенов` : "";
    return [item(base, 0, "compact", L`Контекст сжат ${triggerText}${pre}`.replace(/ {2}/g, " "))];
  }
  const content = str(entry.content);
  if (content) {
    const isError = str(entry.level) === "error";
    return [item(base, 0, isError ? "apiError" : "note", Snippet.firstLine(content, 160), Snippet.truncate(content, DETAIL_LIMIT), isError)];
  }
  return [];
}

function parseQueue(entry: Json, base: Base, timestampString: string): ActivityItem[] {
  const operation = str(entry.operation) ?? "";
  const content = str(entry.content) ?? "";
  const make = (title: string): ActivityItem => ({
    id: `queue|${base.sessionID}|${timestampString}|${operation}`,
    kind: "queued",
    timestamp: base.timestamp,
    sessionID: base.sessionID,
    projectPath: base.projectPath,
    isSidechain: false,
    title,
    detail: content ? Snippet.truncate(content, DETAIL_LIMIT) : undefined,
    isError: false,
  });
  if (operation === "enqueue") return content ? [make(L`В очереди: ` + Snippet.firstLine(content, 140))] : [];
  if (operation === "remove") return [make(L`Убрано из очереди` + (content ? ": " + Snippet.firstLine(content, 120) : ""))];
  return [];
}

// MARK: Helpers

/** Text of a content field that is either a string or a list of blocks. */
export function textContent(content: unknown): string {
  if (typeof content === "string") return content;
  const blocks = blocksOf(content);
  if (!blocks) return "";
  return blocks
    .map((b) => (typeof b.text === "string" ? b.text : b.content !== undefined ? textContent(b.content) : undefined))
    .filter((t): t is string => t !== undefined)
    .join("\n");
}

function imageCount(content: unknown): number {
  return (blocksOf(content) ?? []).filter((b) => b.type === "image").length;
}

/** Value of <name>...</name> in text. */
export function tag(name: string, text: string): string | undefined {
  const open = `<${name}>`;
  const start = text.indexOf(open);
  if (start < 0) return undefined;
  const end = text.indexOf(`</${name}>`, start + open.length);
  if (end < 0) return undefined;
  return text.slice(start + open.length, end).trim();
}

/** {"decision":"accept","reasonType":"rule","ruleSource":"cliArg"} -> "accept · правило (cliArg)". */
export function permissionLabel(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  const decision = obj(value);
  if (!decision) return undefined;
  const verdict = str(decision.decision) ?? "?";
  const reasonType = str(decision.reasonType) ?? "";
  let reason: string;
  switch (reasonType) {
    case "rule": reason = L`правило`; break;
    case "classifier": reason = L`классификатор auto mode`; break;
    case "user": case "userApproval": reason = L`пользователь`; break;
    case "": reason = str(decision.source) ?? ""; break;
    default: reason = reasonType;
  }
  const rule = str(decision.ruleSource);
  if (rule) reason += ` (${rule})`;
  return reason ? `${verdict} · ${reason}` : verdict;
}
