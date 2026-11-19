// "LLM-запросы": every request to the model with its API-level details, and the agent loop
// (thought → action → result) of each turn. Port of Views/Trace/TraceLLMView.swift.
import { useState } from "preact/hooks";
import { Snippet } from "../../core/activity";
import { Fmt } from "../../core/fmt";
import {
  cacheMissTitle, callCost, callDetails, callHasIssue, callModelSwitched, decisionTitle, droppedReasonTitle, droppedThinking,
  isRealMiss, iterationTitle, missExtraCost, stopReasonInfo, thinkingDisplayTitle, type LLMCall, type Tone,
} from "../../core/llm";
import { cacheHitRate, cacheWrite, contextTokens, contextWindow, displayModelName } from "../../core/model";
import { stepDuration, toolCat, toolDuration, type SessionTrace, type ToolExecution } from "../../core/trace";
import * as I from "../icons";
import { store, useStore } from "../state";
import { C, categoryIcon, kindColor, kindIcon } from "../traceStyle";
import { Chip, DetailBlock, Icon, Legend, Segmented, StatTile, Tiles, Toggle } from "../ui";
import { itemTitle, ToolStatusChip } from "./traceParts";
import { L } from "../../core/i18n";

export const toneColor: Record<Tone, string> = { good: C.good, info: C.tool, warning: C.warning, critical: C.critical, neutral: C.other };

/** Segment colors: cache read, cache write, fresh input; thinking and visible output. */
export const SEG = { read: "var(--seg-read)", write: "var(--seg-write)", input: "var(--seg-input)", thinking: "var(--seg-thinking)", output: "var(--seg-output)" };

export function TraceLLMView({ trace }: { trace: SessionTrace }) {
  const s = useStore();
  const calls = s.llmCalls(trace.sessionID);
  const [mode, setMode] = useState<"calls" | "loop">("calls");
  const hide = s.settings.hideContent;
  return (
    <div class="page">
      <CallTiles calls={calls} />
      <div class="row gap-12 wrap">
        <Segmented value={mode} options={[{ id: "calls", title: L`Запросы` }, { id: "loop", title: L`Цикл агента` }]} onChange={setMode} label={L`Вид`} />
        <span class="caption secondary">
          {mode === "calls" ? L`каждый вызов модели: токены, кэш, причина остановки, размышления и действия` : L`мысль → действие → результат для каждого запроса хода`}
        </span>
      </div>
      {calls.length === 0 ? <div class="secondary empty-note" style={{ minHeight: "80px" }}>{L`Запросов к модели в этой сессии пока нет`}</div>
        : mode === "calls" ? <CallList calls={calls} hide={hide} /> : <AgentLoop trace={trace} calls={calls} hide={hide} />}
    </div>
  );
}

function CallTiles({ calls }: { calls: LLMCall[] }) {
  const main = calls.filter((c) => !c.step.isSidechain).length;
  let read = 0;
  let context = 0;
  let misses = 0;
  let extra = 0;
  let dropped = 0;
  let droppedCalls = 0;
  const stops = new Map<string, number>();
  for (const call of calls) {
    const p = call.priced;
    if (p) {
      read += p.event.tokens.cacheRead;
      context += contextTokens(p.event.tokens);
    }
    const d = callDetails(call);
    if (d.cacheMiss && isRealMiss(d.cacheMiss.reason) && p) {
      misses++;
      extra += missExtraCost(store.pricing, p, d.cacheMiss.missedTokens ?? cacheWrite(p.event.tokens));
    }
    const n = droppedThinking(d);
    dropped += n;
    if (n) droppedCalls++;
    const stop = d.stopReason ?? call.step.stopReason;
    if (stop) stops.set(stop, (stops.get(stop) ?? 0) + 1);
  }
  const topStop = [...stops.entries()].sort((a, b) => b[1] - a[1])[0];
  const others = [...stops.entries()].filter(([k]) => k !== topStop?.[0]).map(([k, v]) => `${stopReasonInfo(k).title} ${v}`).join(" · ");
  return (
    <Tiles>
      <StatTile title={L`Запросов к модели`} value={String(calls.length)} caption={L`основной поток ${main} · субагенты ${calls.length - main}`} icon={I.Brain} />
      <StatTile title={L`Чтение из кэша`} value={context > 0 ? Fmt.percent(read / context) : "—"} caption={L`доля контекста всех запросов`} icon={I.MemoryStick} />
      <StatTile title={L`Промахи кэша`} value={String(misses)} caption={misses ? L`≈${Fmt.usd(extra)} лишней записи` : L`с понятной причиной — нет`} icon={I.TriangleExclamationPoint} tint={misses ? C.warning : undefined} />
      <StatTile title={L`Потеряно размышлений`} value={String(dropped)} caption={dropped ? L`блоков в ${Fmt.plural(droppedCalls, "запросе", "запросах", "запросах")}` : L`API ничего не отбрасывало`} icon={I.Brain} tint={dropped ? C.warning : undefined} />
      <StatTile
        title={L`Чем заканчивались ответы`}
        value={topStop ? Fmt.percent(topStop[1] / Math.max(calls.length, 1)) : "—"}
        caption={topStop ? `${stopReasonInfo(topStop[0]).title}${others ? " · " + others : ""}` : undefined}
        icon={I.CircleStop}
      />
    </Tiles>
  );
}

// MARK: Calls

function CallList({ calls, hide }: { calls: LLMCall[]; hide: boolean }) {
  const [onlyIssues, setOnlyIssues] = useState(false);
  const [limit, setLimit] = useState(40);
  const [toggled, setToggled] = useState<Set<number>>(new Set());
  const latest = calls[calls.length - 1]?.index;
  const shown = [...calls].reverse().filter((c) => !onlyIssues || callHasIssue(c));
  const maxContext = Math.max(...calls.map((c) => (c.priced ? contextTokens(c.priced.event.tokens) : 0)), 1);
  const maxOutput = Math.max(...calls.map((c) => c.priced?.event.tokens.output ?? 0), 1);
  const flip = (index: number) => {
    const next = new Set(toggled);
    if (next.has(index)) next.delete(index);
    else next.add(index);
    setToggled(next);
  };
  return (
    <div class="stack-10">
      <div class="row gap-14 wrap">
        <Toggle checked={onlyIssues} onChange={setOnlyIssues} label={L`Только с проблемами`} title={L`промахи кэша, потерянные размышления, отказы, обрезанные ответы, ошибки инструментов`} />
        <span class="caption secondary">{Fmt.plural(shown.length, "запрос", "запроса", "запросов")}</span>
        <span class="spacer" />
        <Legend items={[
          { name: L`чтение кэша`, color: SEG.read }, { name: L`запись в кэш`, color: SEG.write }, { name: L`свежий ввод`, color: SEG.input },
          { name: L`размышления`, color: SEG.thinking }, { name: L`вывод`, color: SEG.output },
        ]} />
      </div>
      {shown.slice(0, limit).map((call) => (
        <CallCard
          key={call.index}
          call={call}
          hide={hide}
          expanded={(call.index === latest) !== toggled.has(call.index)}
          toggle={() => flip(call.index)}
          maxContext={maxContext}
          maxOutput={maxOutput}
        />
      ))}
      {shown.length > limit ? <button class="btn more" type="button" onClick={() => setLimit(limit + 40)}>{L`Показать ещё ${Math.min(40, shown.length - limit)}`}</button> : null}
      {shown.length === 0 ? <div class="secondary empty-note">{L`Запросов с проблемами нет`}</div> : null}
    </div>
  );
}

function CallCard(props: { call: LLMCall; hide: boolean; expanded: boolean; toggle: () => void; maxContext: number; maxOutput: number }) {
  const { call, hide, expanded } = props;
  const d = callDetails(call);
  const p = call.priced;
  const t = p?.event.tokens;
  const stop = stopReasonInfo(d.stopReason ?? call.step.stopReason, d.stopCategory);
  const model = call.step.model ?? p?.event.model;
  const requested = call.step.requestedModel ?? d.requestedModel;
  const effort = call.step.effort ?? p?.event.effort;
  return (
    <div class={callHasIssue(call) ? "card call-card issue" : "card call-card"}>
      <button class="call-head" type="button" onClick={props.toggle}>
        <Icon icon={expanded ? I.ChevronDown : I.ChevronRight} size={14} class="secondary" />
        <span class="strong num">#{call.index}</span>
        <span class="caption num secondary">{Fmt.time(call.step.start)}</span>
        {model ? <Chip text={displayModelName(model)} icon={I.Cpu} tint={C.model} /> : null}
        {callModelSwitched(call) && requested ? <Chip text={L`запрошена ${displayModelName(requested)}`} icon={I.ArrowLeftRight} tint={C.warning} /> : null}
        {effort ? <Chip text={`effort ${effort}`} icon={I.SlidersHorizontal} tint={C.other} /> : null}
        {p?.event.speed === "fast" ? <Chip text="fast" icon={I.Zap} tint={C.warning} /> : null}
        {call.step.isSidechain ? <Chip text={L`субагент`} icon={I.Users} tint={C.subagent} /> : null}
        {d.advisorModel ? <Chip text={L`советник ${displayModelName(d.advisorModel)}`} icon={I.Lightbulb} tint={C.other} /> : null}
        <Chip text={stop.title} tint={toneColor[stop.tone]} />
        <span class="spacer" />
        <span class="caption num secondary nowrap">
          {Fmt.shortDuration(stepDuration(call.step))}
          {t ? ` · ${Fmt.tokens(contextTokens(t))} → ${Fmt.tokens(t.output)}` : ""}
          {p ? ` · ${Fmt.usd(callCost(call))}` : ""}
        </span>
      </button>
      {t ? <TokenBars call={call} maxContext={props.maxContext} maxOutput={props.maxOutput} /> : <div class="caption secondary">{L`Токены этого ответа в логе не найдены`}</div>}
      <CallNotes call={call} />
      {expanded ? <CallBody call={call} hide={hide} /> : null}
    </div>
  );
}

function TokenBars({ call, maxContext, maxOutput }: { call: LLMCall; maxContext: number; maxOutput: number }) {
  const t = call.priced!.event.tokens;
  const context = contextTokens(t);
  const window = contextWindow(call.priced!.event.model);
  const write = cacheWrite(t);
  const visible = Math.max(0, t.output - t.thinking);
  const width = (v: number, max: number) => `${Math.max(0, (v / Math.max(max, 1)) * 100)}%`;
  return (
    <div class="token-bars">
      <span class="caption secondary">{L`вход`}</span>
      <div class="token-track" title={L`чтение кэша ${Fmt.tokens(t.cacheRead)} · запись ${Fmt.tokens(write)} · свежий ввод ${Fmt.tokens(t.input)}`}>
        <div class="segbar thin" style={{ width: `max(3px, ${width(context, maxContext)})` }}>
          {t.cacheRead > 0 ? <span style={{ flexGrow: t.cacheRead, background: SEG.read }} /> : null}
          {write > 0 ? <span style={{ flexGrow: write, background: SEG.write }} /> : null}
          {t.input > 0 ? <span style={{ flexGrow: t.input, background: SEG.input }} /> : null}
        </div>
      </div>
      <span class="caption num secondary nowrap">
        {L`${Fmt.tokens(context)} · ${Fmt.percent(context / window)} окна · из кэша ${Fmt.percent(cacheHitRate(t))}${write > 0 ? L` · запись ${Fmt.tokens(write)}${t.cacheWrite1h > 0 ? L` (1 ч)` : L` (5 мин)`}` : ""}`}
         </span>
      <span class="caption secondary">{L`выход`}</span>
      <div class="token-track" title={L`размышления ${Fmt.tokens(t.thinking)} · вывод ${Fmt.tokens(visible)}`}>
        <div class="segbar thin" style={{ width: `max(3px, ${width(t.output, maxOutput)})` }}>
          {t.thinking > 0 ? <span style={{ flexGrow: t.thinking, background: SEG.thinking }} /> : null}
          {visible > 0 ? <span style={{ flexGrow: visible, background: SEG.output }} /> : null}
        </div>
      </div>
      <span class="caption num secondary nowrap">
        {Fmt.tokens(t.output)}{t.thinking > 0 ? L` · размышления ${Fmt.tokens(t.thinking)}` : ""}
      </span>
    </div>
  );
}

/** Cache miss, dropped thinking, context edits, iterations, model switch: one line each. */
function CallNotes({ call }: { call: LLMCall }) {
  const d = callDetails(call);
  const p = call.priced;
  const notes: { icon: typeof I.Info; color: string; text: string }[] = [];
  if (d.cacheMiss) {
    const real = isRealMiss(d.cacheMiss.reason);
    const tokens = d.cacheMiss.missedTokens ?? (p ? cacheWrite(p.event.tokens) : 0);
    const extra = real && p ? missExtraCost(store.pricing, p, tokens) : 0;
    notes.push(real
      ? { icon: I.TriangleExclamationPoint, color: C.warning, text: L`Промах кэша: ${cacheMissTitle(d.cacheMiss.reason)} — ${Fmt.tokens(tokens)} токенов записаны заново${extra > 0 ? ` (≈${Fmt.usd(extra)})` : ""}` }
      : { icon: I.Info, color: C.other, text: L`Кэш: ${cacheMissTitle(d.cacheMiss.reason)}` });
  }
  for (const t of d.transformations ?? []) {
    if (t.type === "thinking_dropped") notes.push({ icon: I.Brain, color: C.warning, text: L`API убрало размышление из истории: ${droppedReasonTitle(t.reason)}${t.path ? ` (${t.path})` : ""}` });
    else notes.push({ icon: I.Info, color: C.other, text: L`Изменение запроса API: ${t.type}${t.reason ? ` — ${t.reason}` : ""}` });
  }
  for (const e of d.contextEdits ?? []) {
    const parts = [e.clearedTokens !== undefined ? L`${Fmt.tokens(e.clearedTokens)} токенов` : undefined, e.clearedToolUses !== undefined ? L`${e.clearedToolUses} вызовов` : undefined].filter(Boolean);
    notes.push({ icon: I.Minimize2, color: C.context, text: L`Сервер очистил контекст (${e.type})${parts.length ? ": " + parts.join(", ") : ""}` });
  }
  if (d.iterations?.length) {
    const steps = d.iterations.map((i) => L`${iterationTitle(i.type)}${i.model ? ` (${displayModelName(i.model)})` : ""}: вывод ${Fmt.tokens(i.output)}`);
    notes.push({ icon: I.Layers, color: C.other, text: L`Шаги запроса: ${steps.join(" → ")}` });
  }
  if (callModelSwitched(call)) {
    notes.push({ icon: I.ArrowLeftRight, color: C.warning, text: L`Запрошена ${displayModelName(call.step.requestedModel ?? d.requestedModel ?? "")}, ответила ${displayModelName(call.step.model ?? p?.event.model ?? "")}` });
  }
  if (!notes.length) return null;
  return (
    <div class="stack-3">
      {notes.map((n, i) => (
        <div class="row top gap-6 caption" key={i}>
          <Icon icon={n.icon} size={13} color={n.color} />
          <span>{n.text}</span>
        </div>
      ))}
    </div>
  );
}

function CallBody({ call, hide }: { call: LLMCall; hide: boolean }) {
  const d = callDetails(call);
  const p = call.priced;
  const meta = [
    call.step.messageID,
    p?.event.requestID,
    p?.event.serviceTier ? `tier ${p.event.serviceTier}` : undefined,
    d.inferenceGeo ? L`регион ${d.inferenceGeo}` : undefined,
    p?.event.speed ? L`скорость ${p.event.speed}` : undefined,
    d.cacheTTL ? L`TTL кэша ${d.cacheTTL}` : undefined,
    p?.event.webSearchRequests ? L`веб-поиск ${p.event.webSearchRequests}` : undefined,
  ].filter(Boolean);
  return (
    <div class="stack-10 call-body">
      <section class="stack-6">
        <div class="caption strong secondary">{L`Размышления`}</div>
        {call.thinking.length === 0 ? <div class="caption secondary">{L`Без блока размышлений`}</div> : call.thinking.map((item) => (
          <div class="stack-4" key={item.id}>
            <div class="row gap-6 caption">
              <Icon icon={I.Brain} size={13} color={C.model} />
              <span>{item.thinkingMs ? L`думал ${Fmt.ms(item.thinkingMs)}` : L`размышление`}</span>
              <span class="secondary">{L`· режим API: ${thinkingDisplayTitle(item.thinkingDisplay)}`}</span>
            </div>
            {item.detail && !hide ? <DetailBlock text={item.detail} />
              : <div class="caption secondary">{hide ? L`Скрыто переключателем «Скрыть содержимое».` : L`Текст размышлений API не возвращает — известны только длительность и ${Fmt.tokens(p?.event.tokens.thinking ?? 0)} токенов размышлений.`}</div>}
          </div>
        ))}
      </section>
      <section class="stack-6">
        <div class="caption strong secondary">{L`Действия (${call.tools.length})`}</div>
        {call.tools.length === 0 ? <div class="caption secondary">{L`Инструменты не вызывались`}</div> : call.tools.map((tool) => <ActionView key={tool.call.id} tool={tool} hide={hide} />)}
      </section>
      {call.replies.length ? (
        <section class="stack-6">
          <div class="caption strong secondary">{L`Ответ`}</div>
          {call.replies.map((r) => (hide ? <div class="caption secondary" key={r.id}>{itemTitle(r, true)}</div> : <DetailBlock key={r.id} text={r.detail ?? r.title} />))}
        </section>
      ) : null}
      <div class="mono caption2 secondary selectable">{meta.join(" · ")}</div>
    </div>
  );
}

function ActionView({ tool, hide }: { tool: ToolExecution; hide: boolean }) {
  const result = tool.result;
  const decision = result ? decisionTitle(result) : undefined;
  return (
    <div class="action">
      <div class="row baseline gap-6">
        <Icon icon={categoryIcon[toolCat(tool)]} size={15} color={result?.isError ? C.critical : kindColor.toolCall} />
        <span class="mono callout ellipsis selectable">{itemTitle(tool.call, hide)}</span>
        <span class="spacer" />
        <ToolStatusChip tool={tool} />
      </div>
      <div class="row gap-10 wrap caption secondary action-meta">
        {tool.call.inputStreamMs ? <span>{L`аргументы генерировались ${Fmt.ms(tool.call.inputStreamMs)}`}</span> : null}
        {decision ? <span>{decision}</span> : null}
        {result?.sandboxed ? <span>{L`в песочнице`}</span> : null}
        {result ? <span>{L`результат ${Fmt.bytes(result.outputBytes ?? 0)} за ${Fmt.shortDuration(toolDuration(tool, Date.now()))}`}</span> : <span>{L`выполняется`}</span>}
      </div>
      {!hide && tool.call.rawInput ? (
        <div class="stack-3">
          <div class="caption2 secondary">{L`Аргументы, которые сгенерировала модель`}</div>
          <DetailBlock text={tool.call.rawInput} />
        </div>
      ) : null}
      {!hide && tool.call.execInput ? (
        <div class="stack-3">
          <div class="caption2 warning-text">{L`Claude Code выполнил с изменёнными аргументами`}</div>
          <DetailBlock text={tool.call.execInput} />
        </div>
      ) : null}
      {result && !hide ? <div class={result.isError ? "caption critical clamp2" : "caption secondary clamp2"}>↳ {result.title}</div> : null}
    </div>
  );
}

// MARK: Agent loop

function AgentLoop({ trace, calls, hide }: { trace: SessionTrace; calls: LLMCall[]; hide: boolean }) {
  const turns = trace.turns.filter((t) => calls.some((c) => c.turn === t.index));
  const [selected, setSelected] = useState<number | undefined>(undefined);
  const turnIndex = selected ?? turns[turns.length - 1]?.index ?? 0;
  const turn = trace.turns.find((t) => t.index === turnIndex);
  const turnCalls = calls.filter((c) => c.turn === turnIndex);
  const cost = turnCalls.reduce((a, c) => a + callCost(c), 0);
  const tools = turnCalls.reduce((a, c) => a + c.tools.length, 0);
  return (
    <div class="stack-12">
      <div class="row gap-12 wrap">
        <select class="select" value={String(turnIndex)} onChange={(e) => setSelected(Number((e.currentTarget as HTMLSelectElement).value))} aria-label={L`Ход`}>
          {turns.map((t) => (
            <option key={t.id} value={String(t.index)}>
              {`${t.prompt ? L`Ход ${t.index}` : L`Начало сессии`} · ${t.prompt ? Snippet.truncate(itemTitle(t.prompt, hide), 60) : L`без промпта`} · ${Fmt.plural(calls.filter((c) => c.turn === t.index).length, "запрос", "запроса", "запросов")}`}
            </option>
          ))}
        </select>
        <span class="caption num secondary">
          {Fmt.plural(turnCalls.length, "запрос", "запроса", "запросов")} · {Fmt.plural(tools, "действие", "действия", "действий")} · {Fmt.usd(cost)}
          {turn ? ` · ${Fmt.shortDuration(Math.max(0, (turn.end - turn.start) / 1000))}` : ""}
        </span>
      </div>
      {turn?.prompt ? (
        <div class="loop-prompt">
          <Icon icon={kindIcon.prompt} size={16} color={kindColor.prompt} />
          <span class="callout">{hide ? itemTitle(turn.prompt, true) : turn.prompt.detail ?? turn.prompt.title}</span>
        </div>
      ) : null}
      <div class="loop-grid">
        <div class="loop-head caption strong secondary">{L`Мысль`}</div>
        <div />
        <div class="loop-head caption strong secondary">{L`Действие`}</div>
        <div />
        <div class="loop-head caption strong secondary">{L`Результат`}</div>
        {turnCalls.map((call) => <LoopRow key={call.index} call={call} hide={hide} />)}
      </div>
    </div>
  );
}

function LoopRow({ call, hide }: { call: LLMCall; hide: boolean }) {
  const d = callDetails(call);
  const t = call.priced?.event.tokens;
  const note = call.thinking.find((x) => x.detail)?.detail;
  const thinkingMs = call.thinking.reduce((a, x) => a + (x.thinkingMs ?? 0), 0);
  const stop = stopReasonInfo(d.stopReason ?? call.step.stopReason, d.stopCategory);
  const miss = d.cacheMiss && isRealMiss(d.cacheMiss.reason);
  return (
    <>
      <div class={call.step.isSidechain ? "loop-cell sidechain" : "loop-cell"}>
        <div class="row gap-6 wrap">
          <span class="strong num caption">#{call.index}</span>
          <Chip text={displayModelName(call.step.model ?? call.priced?.event.model ?? L`модель`)} icon={I.Cpu} tint={C.model} />
          {call.step.isSidechain ? <Chip text={L`субагент`} icon={I.Users} tint={C.subagent} /> : null}
          {miss ? <Chip text={L`промах кэша`} icon={I.TriangleExclamationPoint} tint={C.warning} title={cacheMissTitle(d.cacheMiss!.reason)} /> : null}
          {droppedThinking(d) ? <Chip text={L`размышление потеряно`} icon={I.Brain} tint={C.warning} /> : null}
        </div>
        <div class="caption secondary">
          {thinkingMs ? L`думал ${Fmt.ms(thinkingMs)}` : L`без размышлений`}
          {t ? L` · вход ${Fmt.tokens(contextTokens(t))} · вывод ${Fmt.tokens(t.output)}${t.thinking ? L` (размышления ${Fmt.tokens(t.thinking)})` : ""}` : ""}
        </div>
        {note && !hide ? <div class="caption clamp2 note">«{note}»</div> : null}
      </div>
      <div class="loop-arrow" aria-hidden="true">→</div>
      <div class="loop-cell">
        {call.tools.length ? call.tools.map((tool) => (
          <div class="row gap-6" key={tool.call.id}>
            <Icon icon={categoryIcon[toolCat(tool)]} size={14} color={kindColor.toolCall} />
            <span class="mono caption ellipsis">{itemTitle(tool.call, hide)}</span>
          </div>
        )) : call.replies.length ? (
          <div class="row top gap-6">
            <Icon icon={kindIcon.reply} size={14} color={kindColor.reply} />
            <span class="caption clamp2">{hide ? L`Ответ` : call.replies[0].title}</span>
          </div>
        ) : <span class="caption secondary">—</span>}
        {stop.tone === "warning" || stop.tone === "critical" ? <Chip text={stop.title} tint={toneColor[stop.tone]} /> : null}
      </div>
      <div class="loop-arrow" aria-hidden="true">→</div>
      <div class="loop-cell">
        {call.tools.length ? call.tools.map((tool) => (
          <div class="row gap-6" key={tool.call.id}>
            <ToolStatusChip tool={tool} />
            <span class={tool.result?.isError ? "caption critical ellipsis" : "caption secondary ellipsis"}>
              {tool.result ? (hide ? Fmt.bytes(tool.result.outputBytes ?? 0) : tool.result.title) : L`ждёт результата`}
            </span>
          </div>
        )) : <span class="caption secondary">{stop.tone === "good" ? L`ход завершён` : stop.title}</span>}
      </div>
    </>
  );
}

