// Icons and colors for trace items and live states. Port of Views/Trace/TraceStyle.swift.
// Identity colors: user, model, tools, context; status colors only for states and errors,
// always with an icon and a label.
import type { LucideIcon } from "lucide-preact";
import type { ActivityKind, ToolCategory } from "../core/activity";
import type { InsightSeverity } from "../core/insights";
import type { LiveState, MCPStatus, TurnOutcome } from "../core/trace";
import * as I from "./icons";
import { labels, N } from "../core/i18n";

export const C = {
  model: "var(--c-model)",
  user: "var(--c-user)",
  tool: "var(--c-tool)",
  context: "var(--c-context)",
  subagent: "var(--c-subagent)",
  skill: "var(--c-skill)",
  mcp: "var(--c-mcp)",
  other: "var(--other)",
  accent: "var(--accent)",
  good: "var(--good)",
  warning: "var(--warning)",
  serious: "var(--serious)",
  critical: "var(--critical)",
} as const;

export const kindIcon: Record<ActivityKind, LucideIcon> = {
  prompt: I.User,
  queued: I.Inbox,
  interrupted: I.CircleStop,
  thinking: I.Brain,
  reply: I.MessageSquareText,
  toolCall: I.Wrench,
  toolResult: I.CornerDownLeft,
  hook: I.Link,
  compact: I.Minimize2,
  context: I.Layers,
  apiError: I.OctagonExclamationPoint,
  note: I.Info,
};

export const kindColor: Record<ActivityKind, string> = {
  prompt: C.user,
  queued: C.user,
  thinking: C.model,
  reply: C.model,
  toolCall: C.tool,
  toolResult: C.tool,
  context: C.context,
  compact: C.context,
  hook: C.other,
  note: C.other,
  interrupted: C.warning,
  apiError: C.critical,
};

export const kindLabel: Record<ActivityKind, string> = labels({
  prompt: N("Промпт"),
  queued: N("Сообщение"),
  interrupted: N("Прерывание"),
  thinking: N("Размышление"),
  reply: N("Ответ"),
  toolCall: N("Инструмент"),
  toolResult: N("Результат"),
  hook: N("Хук"),
  compact: N("Сжатие"),
  context: N("Контекст"),
  apiError: N("Ошибка"),
  note: N("Заметка"),
});

export const stateIcon: Record<LiveState["type"], LucideIcon> = {
  runningTool: I.Hammer,
  runningSubagent: I.Users,
  thinking: I.Brain,
  writing: I.TextCursor,
  waitingForUser: I.MessageSquareCheck,
  quiet: I.MessageSquareMore,
  interrupted: I.CircleStop,
  error: I.OctagonExclamationPoint,
  idle: I.Moon,
};

export const stateColor: Record<LiveState["type"], string> = {
  runningTool: C.tool,
  runningSubagent: C.tool,
  thinking: C.model,
  writing: C.model,
  waitingForUser: C.good,
  quiet: C.other,
  interrupted: C.warning,
  error: C.critical,
  idle: C.other,
};

export const categoryIcon: Record<ToolCategory, LucideIcon> = {
  "Оболочка": I.Terminal,
  "Чтение": I.FileText,
  "Изменение файлов": I.Pencil,
  "Поиск": I.Search,
  "Веб": I.Globe,
  "Субагенты": I.Users,
  "Скиллы": I.Sparkles,
  "MCP": I.Puzzle,
  "Планирование": I.ListChecks,
  "Другое": I.Hammer,
};

export const mcpColor: Record<MCPStatus, string> = {
  connected: C.good,
  pending: C.warning,
  failed: C.critical,
  needsAuth: C.serious,
  usedOnly: C.other,
};

export const mcpIcon: Record<MCPStatus, LucideIcon> = {
  connected: I.CircleCheck,
  pending: I.Hourglass,
  failed: I.OctagonX,
  needsAuth: I.Key,
  usedOnly: I.CircleDashed,
};

export const outcomeTitle: Record<TurnOutcome, string> = labels({
  inProgress: N("идёт"),
  completed: N("завершён"),
  interrupted: N("прерван"),
  failed: N("ошибка"),
});

export const outcomeColor: Record<TurnOutcome, string> = {
  inProgress: C.model,
  completed: C.good,
  interrupted: C.warning,
  failed: C.critical,
};

export const severityColor: Record<InsightSeverity, string> = {
  good: C.good,
  info: C.model,
  warning: C.warning,
  critical: C.critical,
};

export const severityIcon: Record<InsightSeverity, LucideIcon> = {
  good: I.CircleCheck,
  info: I.Lightbulb,
  warning: I.TriangleExclamationPoint,
  critical: I.OctagonX,
};
