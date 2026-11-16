// Live trace: what Claude Code is doing right now and every step it took, in full detail.
// Port of Views/Trace/{TraceView,TraceFeedView,TraceFlowView}.swift.
import { useState } from "preact/hooks";
import type { ActivityItem } from "../../core/activity";
import { Fmt } from "../../core/fmt";
import { displayModelName } from "../../core/model";
import { costTotal, type PricedEvent } from "../../core/pricing";
import {
  flowNodeID, sessionActivityProject, stepDuration, toolIsError, traceProjectPath,
  type FlowNode, type ModelStep, type SessionTrace, type ToolExecution, type TraceTurn,
} from "../../core/trace";
import { totalTokens } from "../../core/model";
import * as I from "../icons";
import { store, TRACE_TABS, useStore } from "../state";
import { C, categoryIcon, kindColor, kindIcon, outcomeColor, outcomeTitle } from "../traceStyle";
import { toolCat } from "../../core/trace";
import { Card, Chip, Chips, DetailBlock, Icon, KeyValues, RankedBarList, Segmented, Toggle } from "../ui";
import { SourcesHelp } from "./sources";
import { TraceContextView } from "./traceContext";
import { itemChips, itemTitle, rowIcon, ToolStatusChip, TraceStatusBanner, UsageLine } from "./traceParts";
import { TraceTimelineView } from "./traceTimeline";
import { TraceToolsView } from "./traceTools";

export function TraceView() {
  const s = useStore();
  const sessionID = s.traceSessionID;
  if (!sessionID) {
    return (
      <SourcesHelp
        title="Нет активности за последние 3 дня"
        icon={I.Waypoints}
        message="Как только Claude Code начнёт работать на этом компьютере или облачная сессия пришлёт свой лог, здесь в реальном времени появятся промпты, размышления, вызовы инструментов, MCP, скиллы, субагенты и контекст."
      />
    );
  }
  const trace = s.trace(sessionID);
  const usage = s.usageByMessage(sessionID);
  const hideContent = s.settings.hideContent;
  return (
    <div class="trace-view">
      <div class="trace-top">
        <TraceHeader trace={trace} />
        <TraceStatusBanner trace={trace} usage={usage} />
        <Segmented value={s.traceTab} options={TRACE_TABS} onChange={(tab) => store.set("traceTab", tab)} label="Раздел" class="wide" />
      </div>
      <div class="trace-body" data-scroll>
        {s.traceTab === "feed" ? <TraceFeed key={sessionID} trace={trace} usage={usage} hideContent={hideContent} />
          : s.traceTab === "flow" ? <TraceFlow key={sessionID} trace={trace} usage={usage} hideContent={hideContent} />
            : s.traceTab === "timeline" ? <TraceTimelineView trace={trace} usage={usage} />
              : s.traceTab === "context" ? <TraceContextView trace={trace} usage={usage} />
                : <TraceToolsView trace={trace} />}
      </div>
    </div>
  );
}

/** Session picker, privacy switch and session facts. */
function TraceHeader({ trace }: { trace: SessionTrace }) {
  const s = useStore();
  const sessions = s.traceSessions;
  return (
    <div class="row gap-14">
      <select
        class="select"
        style={{ maxWidth: "520px" }}
        value={s.pinnedTrace ?? ""}
        onChange={(e) => store.set("pinnedTrace", (e.currentTarget as HTMLSelectElement).value || undefined)}
        aria-label="Сессия"
      >
        <option value="">Следовать за активной сессией</option>
        {sessions.map((session) => (
          <option key={session.id} value={session.id}>
            {`${sessionActivityProject(session)} · ${session.gitBranch ?? "—"} · ${Fmt.dateTime(session.lastActivity)} · ${Fmt.plural(session.items, "событие", "события", "событий")}`}
          </option>
        ))}
      </select>
      <Toggle
        checked={s.settings.hideContent}
        onChange={(value) => void s.updateSettings({ hideContent: value })}
        label="Скрыть содержимое"
        title="Скрывает тексты промптов, ответов, команд и выводов — удобно для демонстрации экрана"
      />
      <span class="spacer" />
      <div class="right-col">
        <div class="caption selectable">{traceProjectPath(trace) ?? "—"}</div>
        <div class="caption2 secondary">
          сессия {trace.sessionID.slice(0, 8)} · {Fmt.plural(trace.items.length, "событие", "события", "событий")} · ошибок: {trace.errors}
        </div>
      </div>
    </div>
  );
}

// MARK: Feed

interface FeedRow {
  item: ActivityItem;
  tool?: ToolExecution;
  usage?: PricedEvent;
}

type FeedFilter = "all" | "user" | "model" | "tools" | "context" | "errors";

const FEED_FILTERS: { id: FeedFilter; title: string }[] = [
  { id: "all", title: "Всё" },
  { id: "user", title: "Вы" },
  { id: "model", title: "Модель" },
  { id: "tools", title: "Инструменты" },
  { id: "context", title: "Контекст и система" },
  { id: "errors", title: "Ошибки" },
];

function matches(filter: FeedFilter, item: ActivityItem): boolean {
  switch (filter) {
    case "all": return true;
    case "user": return item.kind === "prompt" || item.kind === "queued" || item.kind === "interrupted";
    case "model": return item.kind === "thinking" || item.kind === "reply";
    case "tools": return item.kind === "toolCall" || item.kind === "toolResult";
    case "context": return item.kind === "context" || item.kind === "compact" || item.kind === "hook" || item.kind === "note";
    case "errors": return item.isError || item.kind === "apiError" || item.kind === "interrupted";
  }
}

/** Reverse-chronological feed of everything that happened, newest first. */
function TraceFeed({ trace, usage, hideContent }: { trace: SessionTrace; usage: Map<string, PricedEvent>; hideContent: boolean }) {
  const [filter, setFilter] = useState<FeedFilter>("all");
  const [query, setQuery] = useState("");
  const [limit, setLimit] = useState(250);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  const toolsByCall = new Map<string, ToolExecution>();
  for (const tool of trace.tools) if (!toolsByCall.has(tool.call.id)) toolsByCall.set(tool.call.id, tool);
  const answered = new Set(trace.tools.filter((t) => t.result && t.call.toolUseID).map((t) => t.call.toolUseID!));
  const seen = new Set<string>();
  const needle = query.trim().toLocaleLowerCase();
  const rows: FeedRow[] = [];
  for (const item of trace.items) {
    // Results are shown inside their tool call row.
    if (item.kind === "toolResult" && item.toolUseID && answered.has(item.toolUseID) && !item.messageID) continue;
    let rowUsage: PricedEvent | undefined;
    if (item.messageID && !seen.has(item.messageID)) {
      seen.add(item.messageID);
      rowUsage = usage.get(item.messageID);
    }
    const tool = toolsByCall.get(item.id);
    if (!(matches(filter, item) || (filter === "errors" && tool && toolIsError(tool)))) continue;
    if (needle) {
      const haystack = [item.title, item.detail ?? "", item.target ?? "", tool?.result?.detail ?? ""].join("\n").toLocaleLowerCase();
      if (!haystack.includes(needle)) continue;
    }
    rows.push({ item, tool, usage: rowUsage });
  }
  rows.reverse();

  const toggle = (id: string) => {
    const next = new Set(expanded);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setExpanded(next);
  };

  return (
    <div class="feed">
      <div class="row gap-12 feed-bar">
        <Segmented value={filter} options={FEED_FILTERS} onChange={setFilter} label="Фильтр" />
        <input class="search" type="search" placeholder="Поиск по командам, файлам, текстам" value={query} onInput={(e) => setQuery((e.currentTarget as HTMLInputElement).value)} />
        <span class="spacer" />
        <span class="caption secondary">{rows.length} событий</span>
      </div>
      <div class="feed-list">
        {rows.slice(0, limit).map((row) => (
          <FeedRowView key={row.item.id} row={row} hideContent={hideContent} expanded={expanded.has(row.item.id)} toggle={() => toggle(row.item.id)} />
        ))}
        {rows.length > limit ? (
          <button class="btn more" type="button" onClick={() => setLimit(limit + 250)}>Показать ещё {Math.min(250, rows.length - limit)}</button>
        ) : null}
      </div>
    </div>
  );
}

function FeedRowView({ row, hideContent, expanded, toggle }: { row: FeedRow; hideContent: boolean; expanded: boolean; toggle: () => void }) {
  const item = row.item;
  const [icon, color] = rowIcon(item, row.tool);
  const hasDetail = item.detail !== undefined || row.tool?.result !== undefined;
  const result = row.tool?.result;
  return (
    <div class="feed-row" onDblClick={() => hasDetail && toggle()}>
      <div class="row baseline gap-8">
        <span class="caption num secondary time-col">{Fmt.time(item.timestamp)}</span>
        <Icon icon={icon} size={15} color={color} />
        <span class={item.kind === "toolCall" ? "mono callout feed-title selectable" : "callout feed-title selectable"} style={{ WebkitLineClamp: expanded ? 6 : 1 }}>
          {itemTitle(item, hideContent)}
        </span>
        <span class="spacer" />
        {row.tool ? <ToolStatusChip tool={row.tool} /> : null}
        {hasDetail ? (
          <button class="btn borderless icon-only" type="button" onClick={toggle} title={expanded ? "Свернуть" : "Подробнее"}>
            <Icon icon={expanded ? I.ChevronDown : I.ChevronRight} size={14} />
          </button>
        ) : null}
      </div>
      <Chips indent={92}>
        {itemChips(item, row.tool).map((chip) => <Chip key={chip.text} text={chip.text} icon={chip.icon} tint={chip.tint} />)}
      </Chips>
      {row.usage ? <div style={{ paddingLeft: "92px" }}><UsageLine priced={row.usage} /></div> : null}
      {expanded ? (
        <div class="stack-6" style={{ paddingLeft: "92px" }}>
          {!hideContent && item.detail !== undefined ? <DetailBlock text={item.detail} /> : null}
          {result ? (
            <>
              <div class={result.isError ? "caption strong critical" : "caption strong secondary"}>{result.isError ? "Результат (ошибка)" : "Результат"}</div>
              <DetailBlock text={hideContent ? `${Fmt.bytes(result.outputBytes ?? 0)} скрыто` : result.detail ?? result.title} />
            </>
          ) : null}
          {hideContent ? <div class="caption secondary">Содержимое скрыто переключателем «Скрыть содержимое».</div> : null}
        </div>
      ) : null}
    </div>
  );
}

// MARK: Flow

/** Turn-by-turn flow: prompt → model responses → tool calls → results → answer, plus a transition map. */
function TraceFlow({ trace, usage, hideContent }: { trace: SessionTrace; usage: Map<string, PricedEvent>; hideContent: boolean }) {
  // Turns whose expansion differs from the default (latest expanded, others collapsed).
  const [toggled, setToggled] = useState<Set<string>>(new Set());
  const latestID = trace.turns[trace.turns.length - 1]?.id;
  const flip = (id: string) => {
    const next = new Set(toggled);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setToggled(next);
  };
  return (
    <div class="page">
      <div class="row top gap-16 wrap-narrow">
        <Card title="Карта переходов" subtitle="что за чем следует в основном потоке" class="grow">
          {trace.transitions.length === 0 ? <div class="secondary">Переходов пока нет</div> : (
            <RankedBarList rows={trace.transitions.slice(0, 16).map((t) => {
              const id = `${t.from} → ${t.to}`;
              return { id, label: id, value: t.count, valueText: Fmt.plural(t.count, "раз", "раза", "раз") };
            })} />
          )}
        </Card>
        <Card title="Ходы сессии" style={{ maxWidth: "380px", flex: "0 0 380px" }}>
          <TurnSummary trace={trace} usage={usage} />
        </Card>
      </div>
      {[...trace.turns].reverse().map((turn) => (
        <TurnCard
          key={turn.id}
          turn={turn}
          usage={usage}
          hideContent={hideContent}
          expanded={(turn.id === latestID) !== toggled.has(turn.id)}
          toggle={() => flip(turn.id)}
        />
      ))}
    </div>
  );
}

function TurnSummary({ trace, usage }: { trace: SessionTrace; usage: Map<string, PricedEvent> }) {
  const completed = trace.turns.filter((t) => t.outcome === "completed").length;
  const interrupted = trace.turns.filter((t) => t.outcome === "interrupted").length;
  const main = trace.steps.filter((s) => !s.isSidechain).length;
  const thinking = trace.steps.reduce((a, s) => a + s.thinkingMs, 0);
  const streaming = trace.steps.reduce((a, s) => a + s.inputStreamMs, 0);
  const cost = [...usage.values()].reduce((a, p) => a + costTotal(p.cost), 0);
  return (
    <KeyValues rows={[
      ["Ходов", String(trace.turns.filter((t) => t.prompt).length)],
      ["Завершено / прервано", `${completed} / ${interrupted}`],
      ["Ответов модели", `${main} + ${trace.steps.length - main} у субагентов`],
      ["Вызовов инструментов", `${trace.tools.length}, ошибок ${trace.tools.filter(toolIsError).length}`],
      ["Время размышлений", Fmt.ms(thinking)],
      ["Генерация ввода инструментов", Fmt.ms(streaming)],
      ["Сообщений во время работы", String(trace.items.filter((i) => i.kind === "queued" && i.title.startsWith("В очереди")).length)],
      ["API-эквивалент", Fmt.usd(cost)],
    ]} />
  );
}

function TurnCard({ turn, usage, hideContent, expanded, toggle }: { turn: TraceTurn; usage: Map<string, PricedEvent>; hideContent: boolean; expanded: boolean; toggle: () => void }) {
  const cost = turn.stepIDs.reduce((a, id) => a + (usage.get(id) ? costTotal(usage.get(id)!.cost) : 0), 0);
  const tokens = turn.stepIDs.reduce((a, id) => a + (usage.get(id) ? totalTokens(usage.get(id)!.event.tokens) : 0), 0);
  const duration = Math.max(0, (turn.end - turn.start) / 1000);
  return (
    <div class="card">
      <button class="turn-head" type="button" onClick={toggle}>
        <Icon icon={expanded ? I.ChevronDown : I.ChevronRight} size={14} class="secondary" />
        <h3>{turn.prompt ? `Ход ${turn.index}` : "Начало сессии"}</h3>
        <Chip text={outcomeTitle[turn.outcome]} tint={outcomeColor[turn.outcome]} />
        {turn.prompt ? <span class="ellipsis callout">{itemTitle(turn.prompt, hideContent)}</span> : null}
        <span class="spacer" />
        <span class="caption num secondary nowrap">
          {Fmt.dateTime(turn.start)} · {Fmt.shortDuration(duration)} · {turn.stepIDs.length} отв. · {turn.toolCalls} инстр. · {Fmt.tokens(tokens)} ток. · {Fmt.usd(cost)}
        </span>
        {turn.errors > 0 ? <Chip text={`ошибок ${turn.errors}`} icon={I.CircleX} tint={C.critical} /> : null}
      </button>
      {expanded ? (
        <div class="stack-8" style={{ marginTop: "10px" }}>
          {turn.prompt ? (
            <div class="row top gap-8">
              <Icon icon={kindIcon.prompt} size={15} color={kindColor.prompt} />
              {hideContent ? <span>{itemTitle(turn.prompt, true)}</span> : <DetailBlock text={turn.prompt.detail ?? turn.prompt.title} />}
            </div>
          ) : null}
          {turn.nodes.map((node) => <FlowNodeView key={flowNodeID(node)} node={node} usage={usage} hideContent={hideContent} />)}
        </div>
      ) : null}
    </div>
  );
}

function FlowNodeView({ node, usage, hideContent }: { node: FlowNode; usage: Map<string, PricedEvent>; hideContent: boolean }) {
  switch (node.type) {
    case "step": return <FlowStep step={node.step} children={node.children} usage={usage.get(node.step.messageID)} hideContent={hideContent} />;
    case "tool": return <FlowToolRow tool={node.tool} hideContent={hideContent} />;
    case "item": return <FlowItemRow item={node.item} hideContent={hideContent} />;
  }
}

/** A model response with its blocks and tool calls, joined by a connector line. */
function FlowStep({ step, children, usage, hideContent }: { step: ModelStep; children: FlowNode[]; usage?: PricedEvent; hideContent: boolean }) {
  return (
    <div class="stack-4">
      <div class="row baseline gap-6 wrap">
        <Icon icon={I.Brain} size={15} color={C.model} />
        <span class="callout strong">{step.model ? displayModelName(step.model) : "Модель"}</span>
        {step.isSidechain ? <Chip text="субагент" icon={I.Users} tint={C.subagent} /> : null}
        {step.effort ? <Chip text={`effort ${step.effort}`} tint={C.other} /> : null}
        <Chip text={`шаг ${Fmt.shortDuration(stepDuration(step))}`} icon={I.Timer} tint={C.other} />
        {step.thinkingMs > 0 ? <Chip text={`думал ${Fmt.ms(step.thinkingMs)}`} icon={I.Brain} tint={C.model} /> : null}
        {step.inputStreamMs > 0 ? <Chip text={`ввод ${Fmt.ms(step.inputStreamMs)}`} icon={I.Keyboard} tint={C.other} /> : null}
        {step.attributionSkill ? <Chip text={`скилл ${step.attributionSkill}`} icon={I.Sparkles} tint={C.skill} /> : null}
        <span class="spacer" />
        <span class="caption num secondary">{Fmt.time(step.start)}</span>
      </div>
      {usage ? <UsageLine priced={usage} /> : null}
      <div class="flow-children stack-3">
        {children.map((child) =>
          child.type === "tool" ? <FlowToolRow key={flowNodeID(child)} tool={child.tool} hideContent={hideContent} />
            : child.type === "item" ? <FlowItemRow key={flowNodeID(child)} item={child.item} hideContent={hideContent} />
              : null,
        )}
      </div>
    </div>
  );
}

function FlowToolRow({ tool, hideContent }: { tool: ToolExecution; hideContent: boolean }) {
  const isError = toolIsError(tool);
  return (
    <div class="stack-2">
      <div class="row baseline gap-6">
        <Icon icon={categoryIcon[toolCat(tool)]} size={15} color={isError ? C.critical : kindColor.toolCall} />
        <span class="mono callout ellipsis selectable">{itemTitle(tool.call, hideContent)}</span>
        <span class="spacer" />
        <ToolStatusChip tool={tool} />
      </div>
      {tool.result && !hideContent ? (
        <div class={tool.result.isError ? "caption critical ellipsis" : "caption secondary ellipsis"} style={{ paddingLeft: "22px" }}>↳ {tool.result.title}</div>
      ) : null}
    </div>
  );
}

function FlowItemRow({ item, hideContent }: { item: ActivityItem; hideContent: boolean }) {
  const muted = item.kind === "context" || item.kind === "note";
  return (
    <div class="row baseline gap-6">
      <Icon icon={kindIcon[item.kind]} size={15} color={item.isError ? C.critical : kindColor[item.kind]} />
      <span class={muted ? "callout secondary clamp2" : "callout clamp2"}>{itemTitle(item, hideContent)}</span>
      {item.thinkingMs && item.thinkingMs > 0 ? <Chip text={Fmt.ms(item.thinkingMs)} icon={I.Brain} tint={C.model} /> : null}
      <span class="spacer" />
      <span class="caption num secondary">{Fmt.time(item.timestamp)}</span>
    </div>
  );
}
