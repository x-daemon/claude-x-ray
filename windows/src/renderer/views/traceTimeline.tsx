// Gantt chart of model responses and tool runs, context growth on the same time axis, and where
// the session's time went. Port of Views/Trace/TraceTimelineView.swift.
import { useMemo, useRef, useState } from "preact/hooks";
import { Snippet } from "../../core/activity";
import { Fmt } from "../../core/fmt";
import { contextTokens, displayModelName } from "../../core/model";
import type { PricedEvent } from "../../core/pricing";
import { stateIsActive, stepDuration, toolCat, toolDuration, toolIsError, toolIsRunning, toolMcpServer, type SessionTrace } from "../../core/trace";
import { axis, baseOption, EChart, FONT, tokenAxisLabel, tooltipBase, tooltipHTML, type ChartOption } from "../chart";
import * as I from "../icons";
import { store, useNow } from "../state";
import { C } from "../traceStyle";
import { Card, Legend, Segmented, StatTile, Tiles } from "../ui";

type Range = "tenMinutes" | "thirtyMinutes" | "twoHours" | "session";
const RANGES: { id: Range; title: string; ms?: number }[] = [
  { id: "tenMinutes", title: "10 мин", ms: 600_000 },
  { id: "thirtyMinutes", title: "30 мин", ms: 1_800_000 },
  { id: "twoHours", title: "2 часа", ms: 7_200_000 },
  { id: "session", title: "Вся сессия" },
];

type Status = "Модель" | "Успех" | "Ошибка" | "Выполняется";
const STATUS_COLOR: Record<Status, string> = { "Модель": C.model, "Успех": C.tool, "Ошибка": C.critical, "Выполняется": C.warning };

interface Bar {
  id: string;
  lane: string;
  start: number;
  end: number;
  status: Status;
  label: string;
}

export function TraceTimelineView({ trace, usage }: { trace: SessionTrace; usage: Map<string, PricedEvent> }) {
  const [range, setRange] = useState<Range>("thirtyMinutes");
  const now = useNow(2000);
  const isLive = trace.status ? stateIsActive(trace.status.state) : false;
  const traceEnd = trace.items[trace.items.length - 1]?.timestamp;
  const toolEnds = trace.tools.map((t) => t.result?.timestamp ?? -Infinity);
  const reference = isLive ? now : Math.max(traceEnd ?? now, ...toolEnds);
  const sessionStart = trace.items[0]?.timestamp ?? reference - 600_000;
  const span = RANGES.find((r) => r.id === range)!.ms;
  const start = span ? Math.max(sessionStart, reference - span) : sessionStart;
  const width = Math.max(reference - start, 60_000);
  const bars = makeBars(trace, start, reference, width / 300, now);
  const lanes = laneOrder(bars);
  const prompts = trace.items.filter((i) => i.kind === "prompt" && !i.isSidechain && i.timestamp >= start && i.timestamp <= reference);

  return (
    <div class="page">
      <div class="row gap-12">
        <Segmented value={range} options={RANGES} onChange={setRange} label="Окно" />
        <span class="spacer" />
        <span class="caption secondary">{isLive ? "обновляется в реальном времени" : "сессия неактивна, показан её конец"}</span>
      </div>
      <Card title="Что происходило" subtitle="ответы модели и инструменты; пунктир — ваши промпты">
        {bars.length === 0 ? <div class="secondary empty-note" style={{ minHeight: "80px" }}>В этом окне ничего не происходило</div>
          : <Gantt bars={bars.filter((b) => lanes.includes(b.lane))} lanes={lanes} prompts={prompts.map((p) => p.timestamp)} start={start} end={reference} />}
      </Card>
      <Card title="Контекст на каждом запросе" subtitle="токенов в промпте">
        <ContextLineChart usage={usage} start={start} end={reference} />
      </Card>
      <Card title="Куда ушло время сессии">
        <TimeSplit trace={trace} now={now} />
      </Card>
    </div>
  );
}

function makeBars(trace: SessionTrace, start: number, end: number, minWidth: number, now: number): Bar[] {
  const bars: Bar[] = [];
  const clamp = (a: number, b: number): [number, number] | undefined => {
    if (b < start || a > end) return undefined;
    const s = Math.max(a, start);
    const e = Math.min(Math.max(b, s + minWidth), end + minWidth);
    return [s, e];
  };
  for (const step of trace.steps) {
    const range = clamp(step.start, step.end);
    if (!range) continue;
    const model = step.model ? displayModelName(step.model) : "модель";
    const thinking = step.thinkingMs > 0 ? `, думал ${Fmt.ms(step.thinkingMs)}` : "";
    bars.push({
      id: `step|${step.messageID}|${step.start}`,
      lane: step.isSidechain ? "Модель · субагент" : "Модель",
      start: range[0], end: range[1], status: "Модель",
      label: `${model} · ${Fmt.shortDuration(stepDuration(step))}${thinking}`,
    });
  }
  for (const tool of trace.tools) {
    const range = clamp(tool.call.timestamp, tool.result?.timestamp ?? now);
    if (!range) continue;
    const status: Status = toolIsRunning(tool) ? "Выполняется" : toolIsError(tool) ? "Ошибка" : "Успех";
    const server = toolMcpServer(tool);
    const lane = (tool.call.isSidechain ? "↳ " : "") + (server ? `MCP ${server}` : tool.call.toolName ?? "tool");
    bars.push({
      id: `tool|${tool.call.id}`,
      lane,
      start: range[0], end: range[1], status,
      label: `${Snippet.truncate(tool.call.title, 60)} · ${Fmt.shortDuration(toolDuration(tool, now))}`,
    });
  }
  return bars;
}

/** Model lanes first, then tools by first appearance; at most 14 lanes. */
function laneOrder(bars: Bar[]): string[] {
  const lanes: string[] = [];
  for (const fixed of ["Модель", "Модель · субагент"]) if (bars.some((b) => b.lane === fixed)) lanes.push(fixed);
  for (const bar of [...bars].sort((a, b) => a.start - b.start)) if (!lanes.includes(bar.lane)) lanes.push(bar.lane);
  return lanes.slice(0, 14);
}

const TICK_STEPS = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400].map((s) => s * 1000);

function ticks(start: number, end: number): number[] {
  const span = end - start;
  const step = TICK_STEPS.find((s) => span / s <= 7) ?? TICK_STEPS[TICK_STEPS.length - 1];
  const offset = new Date(start).getTimezoneOffset() * 60_000;
  const result: number[] = [];
  for (let t = Math.ceil((start - offset) / step) * step + offset; t <= end; t += step) result.push(t);
  return result;
}

function Gantt({ bars, lanes, prompts, start, end }: { bars: Bar[]; lanes: string[]; prompts: number[]; start: number; end: number }) {
  const plot = useRef<HTMLDivElement>(null);
  const [hover, setHover] = useState<{ time: number; x: number } | undefined>();
  const span = Math.max(end - start, 1);
  const x = (t: number) => `${((t - start) / span) * 100}%`;
  const active = hover ? bars.filter((b) => b.start <= hover.time && hover.time <= b.end).slice(0, 6) : [];

  const onMove = (event: MouseEvent) => {
    const rect = plot.current!.getBoundingClientRect();
    const fraction = Math.min(Math.max((event.clientX - rect.left) / rect.width, 0), 1);
    setHover({ time: start + fraction * span, x: fraction });
  };

  return (
    <div class="gantt">
      <div class="gantt-grid" style={{ gridTemplateRows: `repeat(${lanes.length}, 28px) 22px` }}>
        {lanes.map((lane, i) => <div key={lane} class="gantt-lane caption ellipsis" style={{ gridRow: i + 1 }} title={lane}>{lane}</div>)}
        <div class="gantt-plot" ref={plot} style={{ gridRow: `1 / ${lanes.length + 1}` }} onMouseMove={onMove} onMouseLeave={() => setHover(undefined)}>
          {ticks(start, end).map((t) => <div key={t} class="gantt-gridline" style={{ left: x(t) }} />)}
          {bars.map((bar) => (
            <div
              key={bar.id}
              class="gantt-bar"
              style={{
                left: x(bar.start),
                width: `max(2px, ${((bar.end - bar.start) / span) * 100}%)`,
                top: `${lanes.indexOf(bar.lane) * 28 + 7.5}px`,
                background: STATUS_COLOR[bar.status],
              }}
            />
          ))}
          {prompts.map((t) => <div key={t} class="gantt-prompt" style={{ left: x(t) }} />)}
          {hover ? (
            <>
              <div class="gantt-cursor" style={{ left: `${hover.x * 100}%` }} />
              <div class={hover.x > 0.6 ? "tt floating left" : "tt floating"} style={{ left: `${hover.x * 100}%` }}>
                <div class="tt-title">{Fmt.time(hover.time)}</div>
                {active.length ? active.map((b) => (
                  <div class="tt-row" key={b.id}>
                    <span class="tt-swatch" style={{ background: STATUS_COLOR[b.status] }} />
                    <span class="tt-label">{b.lane}</span>
                    <span class="tt-value">{b.label}</span>
                  </div>
                )) : (
                  <div class="tt-row"><span class="tt-label">Ожидание</span><span class="tt-value">—</span></div>
                )}
              </div>
            </>
          ) : null}
        </div>
        <div class="gantt-axis" style={{ gridRow: lanes.length + 1 }}>
          {ticks(start, end).map((t) => <span key={t} class="caption2 secondary" style={{ left: x(t) }}>{Fmt.time(t)}</span>)}
        </div>
      </div>
      <Legend items={(["Модель", "Успех", "Ошибка", "Выполняется"] as Status[]).map((s) => ({ name: s, color: STATUS_COLOR[s] }))} />
    </div>
  );
}

/** Context tokens per request over time. */
function ContextLineChart({ usage, start, end }: { usage: Map<string, PricedEvent>; start: number; end: number }) {
  const p = store.palette;
  const points = [...usage.values()]
    .filter((e) => e.event.timestamp >= start && e.event.timestamp <= end)
    .sort((a, b) => a.event.timestamp - b.event.timestamp);
  const main = points.filter((e) => !e.event.isSidechain);
  const side = points.filter((e) => e.event.isSidechain);
  const option = useMemo<ChartOption>(() => {
    const line = (name: string, color: string, data: PricedEvent[]) => ({
      type: "line" as const,
      name,
      data: data.map((e) => [e.event.timestamp, contextTokens(e.event.tokens)]),
      lineStyle: { width: 2, color },
      itemStyle: { color, borderColor: p.card, borderWidth: 2 },
      symbol: "circle",
      symbolSize: 7,
      showSymbol: data.length <= 120,
      emphasis: { disabled: true },
    });
    return {
      ...baseOption(p),
      tooltip: {
        ...tooltipBase(p),
        trigger: "axis",
        axisPointer: { type: "line", lineStyle: { color: p.other, opacity: 0.55 } },
        formatter: (params: unknown) => {
          const list = (Array.isArray(params) ? params : [params]) as { seriesName: string; value: [number, number]; color: string }[];
          if (!list.length) return "";
          return tooltipHTML(Fmt.time(list[0].value[0]), list.map((x) => ({ label: x.seriesName, value: Fmt.tokens(x.value[1]), color: x.color })));
        },
      },
      xAxis: { type: "time", min: start, max: end, ...axis(p), axisLabel: { ...axis(p).axisLabel, formatter: (v: number) => Fmt.time(v, false) } },
      yAxis: { type: "value", ...axis(p), axisLabel: { ...axis(p).axisLabel, formatter: tokenAxisLabel } },
      series: [line("Основная сессия", p.roles.model, main), ...(side.length ? [line("Субагент", p.roles.subagent, side)] : [])],
      textStyle: { fontFamily: FONT },
    };
  }, [points.length, start, end, p, points[points.length - 1]?.event.messageID]);

  if (!points.length) return <div class="secondary empty-note" style={{ minHeight: "60px" }}>Нет запросов в этом окне</div>;
  return (
    <div>
      <EChart option={option} height={170} label="Контекст на каждом запросе" />
      {side.length ? <Legend items={[{ name: "Основная сессия", color: C.model }, { name: "Субагент", color: C.subagent }]} /> : null}
    </div>
  );
}

/** Model time, tool time, subagents and waiting for the user. */
function TimeSplit({ trace, now }: { trace: SessionTrace; now: number }) {
  const model = trace.steps.filter((s) => !s.isSidechain).reduce((a, s) => a + stepDuration(s), 0);
  const tools = trace.tools.filter((t) => !t.call.isSidechain && toolCat(t) !== "Субагенты").reduce((a, t) => a + toolDuration(t, now), 0);
  const agents = trace.tools.filter((t) => toolCat(t) === "Субагенты" && !t.call.isSidechain).reduce((a, t) => a + toolDuration(t, now), 0);
  let waiting = 0;
  for (let i = 1; i < trace.turns.length; i++) {
    if (trace.turns[i].prompt) waiting += Math.max(0, (trace.turns[i].start - trace.turns[i - 1].end) / 1000);
  }
  const thinking = trace.steps.reduce((a, s) => a + s.thinkingMs, 0) / 1000;
  return (
    <Tiles>
      <StatTile title="Модель отвечала" value={Fmt.shortDuration(model)} caption={`из них размышления ${Fmt.shortDuration(thinking)}`} icon={I.Brain} />
      <StatTile title="Инструменты работали" value={Fmt.shortDuration(tools)} caption={`${trace.tools.length} вызовов`} icon={I.Wrench} />
      <StatTile title="Субагенты" value={Fmt.shortDuration(agents)} caption={`${trace.subagents.reduce((a, s) => a + s.calls, 0)} запусков`} icon={I.Users} />
      <StatTile title="Ожидание вас" value={Fmt.shortDuration(waiting)} caption="между ответом и следующим промптом" icon={I.User} />
    </Tiles>
  );
}
