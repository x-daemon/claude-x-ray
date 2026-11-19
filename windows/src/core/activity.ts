// Activity trace items and tool descriptions. Port of XRayCore/Activity/{ActivityItem,ToolDescriber}.swift.
import { projectName } from "./model";
import { L, N } from "./i18n";

export type ActivityKind =
  | "prompt" | "queued" | "interrupted" | "thinking" | "reply" | "toolCall" | "toolResult"
  | "hook" | "compact" | "context" | "apiError" | "note";

export type FileAction = "read" | "write" | "edit";

/** Structured data carried by context/environment updates. */
export type ContextPayload =
  | { type: "tools"; added: string[]; removed: string[]; pendingMCP: string[]; failedMCP: string[]; needsAuthMCP: string[]; listingChars: number }
  | { type: "skills"; names: string[]; count: number; listingChars: number }
  | { type: "mcpInstructions"; added: string[]; removed: string[]; chars: number }
  | { type: "agents"; added: string[]; removed: string[]; chars: number }
  | { type: "systemPrompt"; chars: number; parts: number }
  | { type: "environment"; values: Record<string, string> }
  | { type: "model"; id: string; name?: string; knowledgeCutoff?: string }
  | { type: "autoMode"; values: Record<string, string> }
  | { type: "permissions"; allowed: string[] }
  | { type: "editedFile"; path: string }
  | { type: "tasks"; count: number }
  | { type: "remoteChange"; commit?: string; pullRequest?: string; url?: string };

/** One step of what Claude Code did, reconstructed from a transcript line. */
export interface ActivityItem {
  id: string;
  kind: ActivityKind;
  /** Epoch milliseconds. */
  timestamp: number;
  sessionID: string;
  projectPath: string;
  gitBranch?: string;
  isSidechain: boolean;
  title: string;
  detail?: string;
  isError: boolean;
  // Assistant side
  messageID?: string;
  model?: string;
  requestedModel?: string;
  stopReason?: string;
  effort?: string;
  thinkingMs?: number;
  inputStreamMs?: number;
  attributionSkill?: string;
  // Tools
  toolUseID?: string;
  toolName?: string;
  target?: string;
  fileAction?: FileAction;
  permission?: string;
  outputBytes?: number;
  linesAdded?: number;
  linesRemoved?: number;
  /** Thinking: how the API returned the text ("omitted", "summarized", "updates"). */
  thinkingDisplay?: string;
  /** Tool call: the arguments as the model generated them (compact JSON, truncated). */
  rawInput?: string;
  /** Tool call: the arguments Claude Code ran, when it changed the model's arguments. */
  execInput?: string;
  /** Tool result: accept or reject. */
  decision?: string;
  /** Tool result: who decided (classifier, rule, user, hook...). */
  decidedBy?: string;
  /** Tool result: where the deciding rule came from (cliArg, localSettings...). */
  ruleSource?: string;
  /** Tool result: the command ran in the sandbox. */
  sandboxed?: boolean;
  // Context
  context?: ContextPayload;
}

export const itemMcpServer = (item: ActivityItem): string | undefined => (item.toolName ? mcpServer(item.toolName) : undefined);
export const itemProjectName = (item: ActivityItem): string => projectName(item.projectPath);

// MARK: Snippets

export const Snippet = {
  truncate(text: string, limit: number): string {
    const chars = [...text];
    return chars.length > limit ? chars.slice(0, limit).join("") + "…" : text;
  },
  /** First non-empty line, trimmed and truncated. */
  firstLine(text: string, limit: number): string {
    const line = text.split(/\r?\n/).find((l) => l.trim().length > 0) ?? text;
    const trimmed = line.trim();
    const extra = /\r|\n/.test(text) && [...trimmed].length <= limit ? " …" : "";
    return Snippet.truncate(trimmed, limit) + extra;
  },
  /** Last two path components: /Users/me/app/Sources/Main.swift -> Sources/Main.swift. */
  shortPath(path: string): string {
    const parts = path.split(/[\\/]/).filter(Boolean);
    return parts.length > 2 ? parts.slice(-2).join("/") : path;
  },
  compactJSON(value: unknown, limit = 800): string {
    try {
      return Snippet.truncate(JSON.stringify(sortKeys(value)), limit);
    } catch {
      return "";
    }
  },
};

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value as object).sort().map((k) => [k, sortKeys((value as Record<string, unknown>)[k])]));
  }
  return value;
}

// MARK: Tools

export type ToolCategory =
  | "Оболочка" | "Чтение" | "Изменение файлов" | "Поиск" | "Веб" | "Субагенты" | "Скиллы" | "MCP" | "Планирование" | "Другое";

export function mcpServer(toolName: string): string | undefined {
  if (!toolName.startsWith("mcp__")) return undefined;
  const parts = toolName.split("__");
  return parts.length >= 2 ? parts[1] : undefined;
}

export function mcpTool(toolName: string): string | undefined {
  if (!toolName.startsWith("mcp__")) return undefined;
  const parts = toolName.split("__");
  return parts.length >= 3 ? parts.slice(2).join("__") : undefined;
}

/** Readable tool name: mcp__Linear__list_issues -> MCP Linear · list_issues. */
export function toolDisplayName(toolName: string): string {
  const server = mcpServer(toolName);
  return server ? `MCP ${server} · ${mcpTool(toolName) ?? toolName}` : toolName;
}

export function toolCategory(toolName: string): ToolCategory {
  if (toolName.startsWith("mcp__")) return "MCP";
  switch (toolName) {
    case "Bash": case "BashOutput": case "KillShell": case "KillBash": case "Monitor": case "PowerShell": return N("Оболочка");
    case "Read": case "NotebookRead": case "ReadMcpResourceTool": case "ListMcpResourcesTool": return N("Чтение");
    case "Write": case "Edit": case "MultiEdit": case "NotebookEdit": return N("Изменение файлов");
    case "Grep": case "Glob": case "LS": case "ToolSearch": return N("Поиск");
    case "WebFetch": case "WebSearch": case "web_search": case "web_fetch": return N("Веб");
    case "Task": case "Agent": case "SendMessage": return N("Субагенты");
    case "Skill": return N("Скиллы");
    case "TodoWrite": case "TaskCreate": case "TaskUpdate": case "TaskList": case "TaskGet": case "ExitPlanMode": case "EnterPlanMode": case "AskUserQuestion":
      return N("Планирование");
    default: return N("Другое");
  }
}

export interface ToolDescription {
  title: string;
  detail?: string;
  target?: string;
  fileAction?: FileAction;
}

/** Turns a tool call's name and input into a readable one-line summary. */
export function describeTool(name: string, input: Record<string, unknown>): ToolDescription {
  const s = (key: string): string | undefined => {
    const v = input[key];
    return typeof v === "string" && v.length > 0 ? v : undefined;
  };
  switch (name) {
    case "Bash":
    case "PowerShell": {
      const command = s("command") ?? "";
      let detail = command ? "$ " + Snippet.truncate(command, 1_500) : undefined;
      const description = s("description");
      if (description) detail = description + (detail ? "\n" + detail : "");
      if (input.run_in_background === true) detail = (detail ?? "") + L`
(в фоне)`;
      return { title: `${name}: ` + Snippet.firstLine(command, 110), detail };
    }
    case "BashOutput": case "KillShell": case "KillBash": {
      const shell = s("bash_id") ?? s("shell_id") ?? "";
      return { title: `${name} ${shell}`.trim() };
    }
    case "Read": {
      const path = s("file_path") ?? "";
      const parts: string[] = [];
      if (typeof input.offset === "number") parts.push(L`с строки ${input.offset}`);
      if (typeof input.limit === "number") parts.push(L`${input.limit} строк`);
      const pages = s("pages");
      if (pages) parts.push(L`страницы ${pages}`);
      return { title: "Read " + Snippet.shortPath(path) + (parts.length ? ` (${parts.join(", ")})` : ""), detail: path, target: path, fileAction: "read" };
    }
    case "Write": {
      const path = s("file_path") ?? "";
      const content = typeof input.content === "string" ? input.content : "";
      const lines = content ? content.split("\n").length : 0;
      return { title: L`Write ${Snippet.shortPath(path)} · ${lines} строк`, detail: L`${path}\n${new TextEncoder().encode(content).length} байт`, target: path, fileAction: "write" };
    }
    case "Edit": {
      const path = s("file_path") ?? "";
      const oldText = typeof input.old_string === "string" ? input.old_string : "";
      const newText = typeof input.new_string === "string" ? input.new_string : "";
      const all = input.replace_all === true ? L` · все вхождения` : "";
      return {
        title: `Edit ${Snippet.shortPath(path)}${all}`,
        detail: `${path}\n− ${Snippet.truncate(oldText, 400)}\n+ ${Snippet.truncate(newText, 400)}`,
        target: path, fileAction: "edit",
      };
    }
    case "MultiEdit": {
      const path = s("file_path") ?? "";
      const count = Array.isArray(input.edits) ? input.edits.length : 0;
      return { title: L`MultiEdit ${Snippet.shortPath(path)} · ${count} правок`, detail: path, target: path, fileAction: "edit" };
    }
    case "NotebookEdit": {
      const path = s("notebook_path") ?? "";
      return { title: `NotebookEdit ${Snippet.shortPath(path)}`, detail: path, target: path, fileAction: "edit" };
    }
    case "Grep": {
      const pattern = s("pattern") ?? "";
      const path = s("path");
      const scope = [path ? Snippet.shortPath(path) : undefined, s("glob"), s("type")].filter(Boolean).join(", ");
      return { title: `Grep «${Snippet.firstLine(pattern, 60)}»` + (scope ? L` в ${scope}` : ""), detail: Snippet.compactJSON(input), target: path };
    }
    case "Glob": {
      const path = s("path");
      return { title: `Glob ${s("pattern") ?? ""}` + (path ? L` в ${Snippet.shortPath(path)}` : ""), detail: Snippet.compactJSON(input), target: path };
    }
    case "LS":
      return { title: `LS ${Snippet.shortPath(s("path") ?? "")}`, target: s("path") };
    case "WebFetch": case "web_fetch": {
      const url = s("url") ?? "";
      let host = url;
      try {
        host = new URL(url).host || url;
      } catch {
        // keep the raw text
      }
      return { title: `WebFetch ${host}`, detail: [url, s("prompt")].filter(Boolean).join("\n"), target: url };
    }
    case "WebSearch": case "web_search": {
      const query = s("query") ?? "";
      return { title: `WebSearch «${Snippet.firstLine(query, 80)}»`, detail: query };
    }
    case "Task": case "Agent": {
      const description = s("description") ?? L`задача`;
      const type = s("subagent_type");
      const prompt = s("prompt");
      return { title: L`Субагент${type ? ` (${type})` : ""}: ${Snippet.firstLine(description, 90)}`, detail: prompt ? Snippet.truncate(prompt, 1_500) : undefined, target: type };
    }
    case "Skill": {
      const skill = s("skill") ?? s("command") ?? "?";
      return { title: `Skill ${skill}`, detail: s("args"), target: skill };
    }
    case "TodoWrite": {
      const todos = Array.isArray(input.todos) ? (input.todos as Record<string, unknown>[]) : [];
      const lines = todos.map((todo) => {
        const status = typeof todo.status === "string" ? todo.status : "";
        const mark = status === "completed" ? "☑" : status === "in_progress" ? "▶" : "☐";
        return `${mark} ${typeof todo.content === "string" ? todo.content : ""}`;
      });
      return { title: L`TodoWrite · ${todos.length} задач`, detail: lines.join("\n") };
    }
    case "AskUserQuestion": {
      const questions = (Array.isArray(input.questions) ? (input.questions as Record<string, unknown>[]) : [])
        .map((q) => q.question)
        .filter((q): q is string => typeof q === "string");
      return { title: L`Вопрос пользователю`, detail: questions.join("\n") };
    }
    case "ExitPlanMode": {
      const plan = s("plan");
      return { title: L`План готов`, detail: plan ? Snippet.truncate(plan, 1_500) : undefined };
    }
    case "ToolSearch":
      return { title: `ToolSearch «${Snippet.firstLine(s("query") ?? "", 80)}»`, detail: Snippet.compactJSON(input) };
    default: {
      const server = mcpServer(name);
      if (server) {
        const tool = mcpTool(name) ?? name;
        const key = ["query", "q", "url", "path", "file_path", "repo", "name", "title", "id"].map(s).find(Boolean);
        return { title: `MCP ${server} · ${tool}` + (key ? `: ${Snippet.firstLine(key, 70)}` : ""), detail: Snippet.compactJSON(input), target: server };
      }
      return { title: name, detail: Object.keys(input).length ? Snippet.compactJSON(input) : undefined };
    }
  }
}
