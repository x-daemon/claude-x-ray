// Pieces of the live trace shared by several screens: titles and chips of items, tool status,
// the usage line of a model response, the live status banner and the session totals.
// Port of TraceText, ToolStatusChip, UsageLine, TraceStatusBanner and SessionTotalsView.
import type { LucideIcon } from "lucide-preact";
import { UsageSummary } from "../../core/analytics";
import { Snippet, itemMcpServer, type ActivityItem } from "../../core/activity";
import { Fmt } from "../../core/fmt";
import { cacheHitRate, cacheWrite, contextTokens, contextWindow, displayModelName, normalizeModel } from "../../core/model";
import { costTotal, type PricedEvent } from "../../core/pricing";
import {
  stateDetail, stateIsActive, stateTitle, toolCat, toolDuration, toolIsError, toolIsRunning, toolMcpServer,
  type LiveStatus, type SessionTrace, type ToolExecution,
} from "../../core/trace";
import * as I from "../icons";
import { useNow } from "../state";
import { C, categoryIcon, kindColor, kindIcon, kindLabel, stateColor, stateIcon } from "../traceStyle";
import { Chip, Icon } from "../ui";
import { L } from "../../core/i18n";

const chars = (text: string): number => [...text].length;

export function itemTitle(item: ActivityItem, hideContent: boolean): string {
  if (!hideContent) return item.title;
  switch (item.kind) {
    case "prompt":
    case "queued":
      return L`${kindLabel[item.kind]} · ${chars(item.detail ?? item.title)} символов`;
    case "reply":
      return L`Ответ · ${chars(item.detail ?? item.title)} символов`;
    case "thinking":
      return L`Размышление`;
    case "toolCall": {
      if (!item.toolName) return L`Инструмент`;
      const server = itemMcpServer(item);
      return server ? `MCP ${server}` : item.toolName;
    }
    case "toolResult":
      return L`Результат · ${Fmt.bytes(item.outputBytes ?? 0)}`;
    default:
      return item.title;
  }
}

export interface ChipSpec {
  text: string;
  icon?: LucideIcon;
  tint: string;
}

export function itemChips(item: ActivityItem, tool?: ToolExecution): ChipSpec[] {
  const chips: ChipSpec[] = [{ text: kindLabel[item.kind], tint: kindColor[item.kind] }];
  const modelKinds = item.kind === "thinking" || item.kind === "reply" || item.kind === "toolCall";
  if (item.isSidechain) chips.push({ text: L`субагент`, icon: I.Users, tint: C.subagent });
  if (item.model && modelKinds) chips.push({ text: displayModelName(item.model), icon: I.Cpu, tint: C.model });
  if (item.requestedModel && item.model && normalizeModel(item.requestedModel) !== normalizeModel(item.model)) {
    chips.push({ text: L`запрошена ${displayModelName(item.requestedModel)}`, icon: I.ArrowLeftRight, tint: C.warning });
  }
  if (item.effort && (item.kind === "thinking" || item.kind === "reply")) chips.push({ text: `effort ${item.effort}`, icon: I.SlidersHorizontal, tint: C.other });
  if (item.thinkingMs && item.thinkingMs > 0) chips.push({ text: L`думал ${Fmt.ms(item.thinkingMs)}`, icon: I.Brain, tint: C.model });
  if (item.inputStreamMs && item.inputStreamMs > 0) chips.push({ text: L`ввод генерировался ${Fmt.ms(item.inputStreamMs)}`, icon: I.Keyboard, tint: C.other });
  const server = itemMcpServer(item);
  if (server) chips.push({ text: `MCP ${server}`, icon: I.Puzzle, tint: C.mcp });
  if (item.attributionSkill) chips.push({ text: L`скилл ${item.attributionSkill}`, icon: I.Sparkles, tint: C.skill });
  if (item.fileAction && item.target) {
    const verb = item.fileAction === "read" ? L`чтение` : item.fileAction === "write" ? L`запись` : L`правка`;
    chips.push({ text: `${verb} ${Snippet.shortPath(item.target)}`, icon: I.File, tint: C.other });
  }
  const result = tool?.result;
  if (result) {
    if (result.linesAdded !== undefined && result.linesRemoved !== undefined) {
      chips.push({ text: L`+${result.linesAdded} −${result.linesRemoved} строк`, icon: I.Diff, tint: C.other });
    } else if (result.linesAdded !== undefined) {
      chips.push({ text: L`+${result.linesAdded} строк`, icon: I.Plus, tint: C.other });
    }
    if (result.outputBytes && result.outputBytes > 0) {
      chips.push({ text: L`вывод ${Fmt.bytes(result.outputBytes)} ≈${Fmt.tokens(Math.floor(result.outputBytes / 4))} ток.`, icon: I.CornerDownLeft, tint: C.other });
    }
    if (result.permission) chips.push({ text: result.permission, icon: I.LockOpen, tint: C.other });
  }
  if (item.kind === "toolResult" && item.outputBytes !== undefined && !tool) chips.push({ text: Fmt.bytes(item.outputBytes), tint: C.other });
  if (item.stopReason && item.kind === "reply" && item.stopReason !== "tool_use") chips.push({ text: `stop: ${item.stopReason}`, tint: C.other });
  return chips;
}

/** Icon and color of a row: the tool category for tool calls, the item kind otherwise. */
export function rowIcon(item: ActivityItem, tool?: ToolExecution): [LucideIcon, string] {
  const isError = item.isError || (tool ? toolIsError(tool) : false);
  const icon = tool ? categoryIcon[toolCat(tool)] : kindIcon[item.kind];
  return [icon, isError ? C.critical : kindColor[item.kind]];
}

/** ✓ 1.2 с / ✗ ошибка / ⏳ выполняется. */
export function ToolStatusChip({ tool }: { tool: ToolExecution }) {
  if (toolIsRunning(tool)) return <RunningChip tool={tool} />;
  const duration = Fmt.shortDuration(toolDuration(tool, Date.now()));
  if (toolIsError(tool)) return <Chip text={L`ошибка · ${duration}`} icon={I.CircleX} tint={C.critical} />;
  return <Chip text={duration} icon={I.CircleCheck} tint={C.good} />;
}

function RunningChip({ tool }: { tool: ToolExecution }) {
  const now = useNow(1000);
  return <Chip text={L`выполняется ${Fmt.shortDuration(toolDuration(tool, now))}`} icon={I.Hourglass} tint={C.warning} />;
}

/** Tokens, context and cost of one model response. */
export function UsageLine({ priced }: { priced: PricedEvent }) {
  const t = priced.event.tokens;
  const window = contextWindow(priced.event.model);
  const context = contextTokens(t);
  const parts = [
    L`контекст ${Fmt.tokens(context)} (${Fmt.percent(context / window)} окна)`,
    L`из кэша ${Fmt.percent(cacheHitRate(t))}`,
  ];
  if (cacheWrite(t) > 0) parts.push(L`запись в кэш ${Fmt.tokens(cacheWrite(t))}${t.cacheWrite1h > 0 ? L` (1 ч)` : ""}`);
  parts.push(L`ввод ${Fmt.tokens(t.input)}`);
  parts.push(L`вывод ${Fmt.tokens(t.output)}` + (t.thinking > 0 ? L` (размышления ${Fmt.tokens(t.thinking)})` : ""));
  if (priced.event.webSearchRequests > 0) parts.push(L`веб-поиск ${priced.event.webSearchRequests}`);
  parts.push(Fmt.usd(costTotal(priced.cost)));
  return (
    <div class="usage-line caption num secondary">
      <Icon icon={I.Gauge} size={13} color={C.model} />
      <span>{parts.join(" · ")}</span>
    </div>
  );
}

/** Big live status: state, what exactly runs, for how long, and session totals. Ticks every second. */
export function TraceStatusBanner({ trace, usage }: { trace: SessionTrace; usage: Map<string, PricedEvent> }) {
  const now = useNow(1000);
  const status = trace.status;
  const state = status?.state ?? { type: "idle" as const };
  const detail = stateDetail(state);
  const color = stateColor[state.type];
  return (
    <div class="status-banner" style={{ "--state": color } as Record<string, string>}>
      <Icon icon={stateIcon[state.type]} size={30} color={color} class={stateIsActive(state) ? "pulse" : undefined} />
      <div class="stack-4 grow min0">
        <div class="row baseline gap-10">
          <span class="title2">{stateTitle(state)}</span>
          {status ? <span class="title3 num secondary">{Fmt.shortDuration(Math.max(0, now - status.since) / 1000)}</span> : null}
        </div>
        {detail ? <div class="mono callout clamp2 selectable">{detail}</div> : null}
        {status ? <div class="caption secondary">{turnLine(status, now)}</div> : null}
      </div>
      <SessionTotals usage={usage} />
    </div>
  );
}

function turnLine(status: LiveStatus, now: number): string {
  const parts: string[] = [];
  if (status.turnStart !== undefined) parts.push(L`ход идёт ${Fmt.shortDuration((now - status.turnStart) / 1000)}`);
  parts.push(L`ответов модели: ${status.stepsInTurn}`);
  parts.push(L`вызовов инструментов: ${status.toolsInTurn}`);
  if (status.runningTools > 1) parts.push(L`параллельно: ${status.runningTools}`);
  parts.push(L`последнее событие ${Fmt.shortDuration(Math.max(0, now - status.lastActivity) / 1000)} назад`);
  return parts.join(" · ");
}

/** Session cost, tokens, current context and cache, from the priced usage. */
export function SessionTotals({ usage }: { usage: Map<string, PricedEvent> }) {
  const events = [...usage.values()].sort((a, b) => a.event.timestamp - b.event.timestamp);
  const summary = UsageSummary.of(events);
  const last = [...events].reverse().find((e) => !e.event.isSidechain) ?? events[events.length - 1];
  const context = last ? contextTokens(last.event.tokens) : 0;
  const window = last ? contextWindow(last.event.model) : 1_000_000;
  const rows: [string, string][] = [
    [L`Сессия`, Fmt.usd(summary.totalCost)],
    [L`Токены`, `${Fmt.tokens(summary.totalTokens)} · ${Fmt.plural(summary.requests, "запрос", "запроса", "запросов")}`],
    [L`Контекст`, L`${Fmt.tokens(context)} из ${Fmt.tokens(window)} · ${Fmt.percent(context / Math.max(window, 1))}`],
    [L`Кэш, последний запрос`, last ? Fmt.percent(cacheHitRate(last.event.tokens)) : "—"],
  ];
  return (
    <div class="totals callout">
      {rows.map(([k, v]) => (
        <div class="kv-row" key={k}>
          <span class="secondary">{k}</span>
          <span class="num">{v}</span>
        </div>
      ))}
    </div>
  );
}

export const toolLabel = (tool: ToolExecution): string => {
  const server = toolMcpServer(tool);
  return server ? `MCP ${server}` : tool.call.toolName ?? "tool";
};
