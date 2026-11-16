// "Обзор": totals, cost timeline, cost structure, model share and the weekday x hour heatmap.
// Port of Views/OverviewView.swift.
import { PieChart } from "echarts/charts";
import * as echarts from "echarts/core";
import { useMemo, useState } from "preact/hooks";
import { Analytics, UsageSummary, type HeatCell, type Interval, type TimeBucket, type CalendarUnit } from "../../core/analytics";
import { Fmt } from "../../core/fmt";
import { cacheWrite } from "../../core/model";
import { costTotal, type PricedEvent } from "../../core/pricing";
import { axis, axisTooltip, baseOption, EChart, stackedBars, tooltipBase, tooltipHTML, usdAxisLabel, type ChartOption, type TooltipRow } from "../chart";
import * as I from "../icons";
import { OTHER_SERIES, PERIODS, store, useStore } from "../state";
import { COMPONENTS } from "../theme";
import { Card, Legend, StatTile, Tiles } from "../ui";

echarts.use([PieChart]);

export const unitTitle = (unit: CalendarUnit): string => (unit === "hour" ? "по часам" : unit === "week" ? "по неделям" : "по дням");

export function OverviewView() {
  const s = useStore();
  const events = s.periodEvents;
  const summary = UsageSummary.of(events);
  const sessions = new Set(events.map((e) => e.event.sessionID)).size;
  const unit = s.periodChartUnit;
  const interval = s.periodInterval();
  const periodTitle = PERIODS.find((p) => p.id === s.period)!.title;
  return (
    <div class="page">
      <Tiles>
        <StatTile title={s.costLabel} value={Fmt.usd(summary.totalCost)} caption={periodTitle} icon={I.Zap} />
        <StatTile title="Токены" value={Fmt.tokens(summary.totalTokens)} caption={`вывод ${Fmt.tokens(summary.tokens.output)}, из них размышления ${Fmt.tokens(summary.tokens.thinking)}`} icon={I.Hash} />
        <StatTile title="Запросы" value={String(summary.requests)} caption={`${sessions} сессий · ${Fmt.usd(summary.costPerRequest)} за запрос`} icon={I.ArrowUpDown} />
        <StatTile title="Доля кэша" value={summary.requests > 0 ? Fmt.percent(summary.cacheHitRate) : "—"} caption={`средний контекст ${Fmt.tokens(Math.trunc(summary.averageContextTokens))}`} icon={I.MemoryStick} />
      </Tiles>
      {interval ? (
        <Card title="Стоимость по времени" subtitle={`по моделям · ${unitTitle(unit)}`}>
          <CostTimelineChart buckets={Analytics.buckets(events, unit, interval, (e) => s.seriesName(e))} unit={unit} interval={interval} />
        </Card>
      ) : null}
      <div class="row top gap-16 wrap-narrow">
        <Card title="Из чего складывается стоимость" class="grow"><CostComposition summary={summary} /></Card>
        <Card title="Доля моделей" style={{ flex: "0 1 420px" }}><ModelShareChart events={events} /></Card>
      </div>
      <Card title="Когда вы работаете" subtitle={`${s.costLabel} по дням недели и часам`}>
        <ActivityHeatmap cells={Analytics.heatmap(events)} />
      </Card>
    </div>
  );
}

function bucketTitle(start: number, unit: CalendarUnit): string {
  return unit === "hour" ? `${Fmt.day(start)} ${Fmt.time(start, false)}` : Fmt.day(start);
}

function bucketLabel(start: number, unit: CalendarUnit): string {
  if (unit === "hour") return Fmt.time(start, false);
  const d = new Date(start);
  return `${String(d.getDate()).padStart(2, "0")}.${String(d.getMonth() + 1).padStart(2, "0")}`;
}

/** Stacked bars per time bucket, one segment per model, with a hover breakdown. */
export function CostTimelineChart({ buckets, unit, interval, height = 260 }: { buckets: TimeBucket[]; unit: CalendarUnit; interval: Interval; height?: number }) {
  const s = store;
  const p = s.palette;
  // Same stacking order in every bucket: by the model's all-time rank.
  const names = new Set<string>();
  for (const b of buckets) for (const k of b.bySeries.keys()) names.add(k);
  const scale = s.colorScale(names);
  const empty = names.size === 0;
  const option = useMemo<ChartOption>(() => ({
    ...baseOption(p),
    tooltip: axisTooltip(p, (i) => {
      const b = buckets[i];
      const rows: TooltipRow[] = [{ label: "Всего", value: Fmt.usd(b.summary.totalCost) }];
      for (const [name, sum] of [...b.bySeries.entries()].sort((x, y) => y[1].totalCost - x[1].totalCost)) {
        const index = scale.domain.indexOf(name);
        rows.push({ label: name, value: Fmt.usd(sum.totalCost), color: index >= 0 ? scale.range[index] : undefined });
      }
      rows.push({ label: "Токены", value: Fmt.tokens(b.summary.totalTokens) });
      return tooltipHTML(bucketTitle(b.start, unit), rows);
    }),
    xAxis: { type: "category", data: buckets.map((b) => bucketLabel(b.start, unit)), ...axis(p, false) },
    yAxis: { type: "value", ...axis(p), min: 0, max: empty ? 1 : undefined, axisLabel: { ...axis(p).axisLabel, formatter: usdAxisLabel } },
    series: stackedBars(p, scale.domain.map((name, i) => ({
      name,
      color: scale.range[i],
      values: buckets.map((b) => b.bySeries.get(name)?.totalCost ?? 0),
    }))).map((series) => (buckets.length > 40 ? { ...series, barCategoryGap: "20%" } : series)),
  }), [buckets, unit, interval.start, interval.end, p, s.modelOrder]);
  return (
    <div>
      <div class="chart-wrap">
        <EChart option={option} height={height} label="Стоимость по времени, по моделям" />
        {empty ? <div class="chart-overlay plain"><span>Нет данных за период</span></div> : null}
      </div>
      {!empty ? <Legend items={scale.domain.map((name, i) => ({ name, color: scale.range[i] }))} /> : null}
    </div>
  );
}

/** One stacked bar of the cost split by component, plus the numbers behind it. */
export function CostComposition({ summary }: { summary: UsageSummary }) {
  const p = store.palette;
  const all = [
    { name: COMPONENTS[0], cost: summary.cost.input, tokens: summary.tokens.input as number | undefined },
    { name: COMPONENTS[1], cost: summary.cost.output, tokens: summary.tokens.output },
    { name: COMPONENTS[2], cost: summary.cost.cacheRead, tokens: summary.tokens.cacheRead },
    { name: COMPONENTS[3], cost: summary.cost.cacheWrite, tokens: cacheWrite(summary.tokens) },
    { name: COMPONENTS[4], cost: summary.cost.webSearch, tokens: undefined },
  ];
  const colors = Object.fromEntries(COMPONENTS.map((name, i) => [name, p.series[i]]));
  const components = all.filter((c) => c.cost > 0);
  const total = Math.max(summary.totalCost, Number.MIN_VALUE);
  return (
    <div class="stack-12">
      {components.length ? (
        <div>
          <div class="segbar tall" role="img" aria-label="Структура стоимости">
            {components.map((c) => <span key={c.name} style={{ flexGrow: c.cost, background: colors[c.name] }} title={`${c.name}: ${Fmt.usd(c.cost)}`} />)}
          </div>
          <div class="segbar-scale caption2 secondary num">
            <span>$0</span><span>{Fmt.usd(summary.totalCost / 2)}</span><span>{Fmt.usd(summary.totalCost)}</span>
          </div>
        </div>
      ) : <div class="secondary">Нет данных за период</div>}
      <div class="grid-5">
        {components.map((c) => (
          <>
            <span class="swatch" style={{ background: colors[c.name] }} />
            <span>{c.name}</span>
            <span class="secondary num">{c.tokens !== undefined ? Fmt.tokens(c.tokens) : "—"}</span>
            <span class="num">{Fmt.usd(c.cost)}</span>
            <span class="secondary num">{Fmt.percent(c.cost / total)}</span>
          </>
        ))}
      </div>
      {summary.tokens.thinking > 0 ? (
        <div class="caption secondary">
          Размышления — {Fmt.percent(summary.tokens.thinking / Math.max(summary.tokens.output, 1))} выходных токенов; они оплачиваются как вывод.
        </div>
      ) : null}
    </div>
  );
}

/** Donut of cost by model with stable model colors, legend with shares on the right. */
function ModelShareChart({ events }: { events: PricedEvent[] }) {
  const s = store;
  const p = s.palette;
  const groups = Analytics.group(events, (e) => s.seriesName(e));
  const scale = s.colorScale(groups.map((g) => g.key));
  const total = groups.reduce((a, g) => a + g.summary.totalCost, 0);
  const colorOf = (name: string) => scale.range[scale.domain.indexOf(name)] ?? p.other;
  const option = useMemo<ChartOption>(() => ({
    animation: false,
    tooltip: {
      ...tooltipBase(p),
      trigger: "item",
      formatter: (params: unknown) => {
        const x = params as { name: string; value: number; color: string };
        return tooltipHTML(x.name, [
          { label: "API-эквивалент", value: Fmt.usd(x.value), color: x.color },
          { label: "Доля", value: Fmt.percent(total > 0 ? x.value / total : 0) },
        ]);
      },
    },
    series: [{
      type: "pie",
      radius: ["62%", "96%"],
      center: ["50%", "50%"],
      padAngle: 1.5,
      itemStyle: { borderRadius: 4, borderColor: p.card, borderWidth: 0 },
      label: { show: false },
      emphasis: { scale: false },
      data: groups.map((g) => ({ name: g.key, value: g.summary.totalCost, itemStyle: { color: colorOf(g.key) } })),
    }],
  } as unknown as ChartOption), [events, p, s.modelOrder]);
  if (!groups.length) return <div class="secondary empty-note" style={{ minHeight: "200px" }}>Нет данных</div>;
  return (
    <div class="donut">
      <div class="donut-chart"><EChart option={option} height={200} label="Доля моделей в стоимости" /></div>
      <div class="donut-legend">
        {groups.map((g) => (
          <div class="legend-item" key={g.key}>
            <span class="swatch" style={{ background: colorOf(g.key) }} />
            <span class="grow">{g.key}</span>
            <span class="num secondary">{Fmt.percent(total > 0 ? g.summary.totalCost / total : 0)}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

const DAYS = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"];
const HOURS = Array.from({ length: 24 }, (_, h) => String(h).padStart(2, "0"));

function hexToRgb(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

/** Color on the sequential ramp for t in 0...1 (linear between steps). */
export function rampColor(ramp: string[], t: number): string {
  const x = Math.min(Math.max(t, 0), 1) * (ramp.length - 1);
  const i = Math.min(Math.floor(x), ramp.length - 2);
  const f = x - i;
  const a = hexToRgb(ramp[i]);
  const b = hexToRgb(ramp[i + 1]);
  const mix = a.map((v, k) => Math.round(v + (b[k] - v) * f));
  return `rgb(${mix[0]}, ${mix[1]}, ${mix[2]})`;
}

/** Weekday x hour grid of API-equivalent spend, with a hover readout. */
export function ActivityHeatmap({ cells, showsHint = true }: { cells: HeatCell[]; showsHint?: boolean }) {
  const [hovered, setHovered] = useState<HeatCell>();
  const ramp = store.palette.sequential;
  const costs = cells.filter((c) => c.cost > 0).map((c) => c.cost);
  const min = costs.length ? Math.min(...costs) : 0;
  const max = costs.length ? Math.max(...costs) : 0;
  return (
    <div class="stack-8">
      <div class="heatmap" onMouseLeave={() => setHovered(undefined)}>
        {DAYS.map((day, d) => (
          <>
            <span class="caption2 secondary heat-day" key={day}>{day}</span>
            {HOURS.map((hour, h) => {
              const cell = cells[d * 24 + h];
              const color = cell.cost > 0 ? rampColor(ramp, max > min ? (cell.cost - min) / (max - min) : 1) : "var(--empty)";
              return (
                <span
                  key={hour}
                  class="heat-cell"
                  style={{ background: color }}
                  title={`${day}, ${hour}:00 — ${Fmt.usd(cell.cost)}, запросов: ${cell.requests}`}
                  onMouseEnter={() => setHovered(cell)}
                />
              );
            })}
          </>
        ))}
        <span />
        {HOURS.map((hour, h) => <span key={hour} class="caption2 secondary heat-hour">{h % 3 === 0 ? hour : ""}</span>)}
      </div>
      <div class="row gap-6 caption2 secondary">
        <span>меньше</span>
        <span class="ramp">{ramp.map((c) => <span key={c} style={{ background: c }} />)}</span>
        <span>больше · до {Fmt.usd(max)} за час</span>
      </div>
      {showsHint ? (
        <div class="caption secondary">
          {hovered ? `${DAYS[hovered.weekday]}, ${HOURS[hovered.hour]}:00 — ${Fmt.usd(hovered.cost)}, запросов: ${hovered.requests}` : "Наведите курсор на ячейку, чтобы увидеть значение."}
        </div>
      ) : null}
    </div>
  );
}
