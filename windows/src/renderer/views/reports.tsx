// "Отчёты": the visual report of the selected period with PDF export and data exports
// (Markdown, CSV). Port of Views/ReportsView.swift and Views/ReportDocument.swift.
import { useEffect, useMemo, useState } from "preact/hooks";
import { Analytics, sessionProject, sessionSummaries, UsageSummary, type HeatCell, type Interval, type SessionSummary } from "../../core/analytics";
import { dailyCSV, markdownReport, sessionsCSV } from "../../core/export";
import { Fmt } from "../../core/fmt";
import { analyzeInsights } from "../../core/insights";
import { projectName } from "../../core/model";
import type { PricedEvent } from "../../core/pricing";
import { axis, baseOption, EChart, FONT, tooltipBase, tooltipHTML, type ChartOption } from "../chart";
import * as I from "../icons";
import { PERIODS, store, useStore } from "../state";
import { applyPalette } from "../theme";
import { C } from "../traceStyle";
import { Button, Card, Icon, RankedBarList, type RankedRow } from "../ui";
import { InsightCard } from "./insights";
import { ActivityHeatmap, CostComposition, CostTimelineChart, unitTitle } from "./overview";

export function ReportsView() {
  const s = useStore();
  const [status, setStatus] = useState<string>();
  const [menu, setMenu] = useState(false);
  const stamp = Fmt.isoDay(s.now);
  const markdown = () =>
    markdownReport("S2A Claude X-Ray — отчёт об использовании Claude Code", PERIODS.find((p) => p.id === s.period)!.title, s.periodEvents, analyzeInsights(s.pricing, s.periodEvents));
  const saved = (file?: string) => file && setStatus(`Сохранено: ${file.split(/[\\/]/).pop()}`);
  const saveText = async (name: string, text: string, kind: "md" | "csv") => {
    setMenu(false);
    try {
      saved(await s.bridge.saveText(name, text, kind));
    } catch (error) {
      setStatus(`Не удалось сохранить: ${(error as Error).message}`);
    }
  };
  const savePDF = async () => {
    try {
      const size = await prepareExport();
      saved(await s.bridge.savePDF(`S2A Claude X-Ray — отчёт ${stamp}.pdf`, size));
    } catch (error) {
      setStatus(`Не удалось построить PDF: ${(error as Error).message}`);
    } finally {
      finishExport();
    }
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.ctrlKey && e.key.toLowerCase() === "s") {
        e.preventDefault();
        void savePDF();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  return (
    <div class="reports">
      <div class="report-toolbar row gap-10">
        <Button icon={I.FileDown} onClick={() => void savePDF()} title="Ctrl+S">Сохранить PDF…</Button>
        <div class="menu-anchor">
          <Button icon={I.Table2} onClick={() => setMenu(!menu)}>Данные <Icon icon={I.ChevronDown} size={12} /></Button>
          {menu ? (
            <div class="menu" onMouseLeave={() => setMenu(false)}>
              <button type="button" onClick={() => void saveText(`claude-xray-${stamp}.md`, markdown(), "md")}>Markdown…</button>
              <button type="button" onClick={() => void saveText(`claude-xray-daily-${stamp}.csv`, dailyCSV(s.periodEvents), "csv")}>CSV по дням…</button>
              <button type="button" onClick={() => void saveText(`claude-xray-sessions-${stamp}.csv`, sessionsCSV(sessionSummaries(s.periodEvents)), "csv")}>CSV по сессиям…</button>
              <hr />
              <button type="button" onClick={async () => { setMenu(false); await s.bridge.copyText(markdown()); setStatus("Отчёт скопирован в буфер обмена"); }}>Копировать как Markdown</button>
            </div>
          ) : null}
        </div>
        <span class="spacer" />
        {status ? <span class="caption secondary">{status}</span> : null}
      </div>
      <div class="report-scroll" data-scroll>
        <ReportDocument />
      </div>
    </div>
  );
}

/**
 * Switches to the light palette and the export layout, sizes the PDF page to the whole report
 * (one long page, like the macOS app) and returns that size in CSS pixels.
 */
export async function prepareExport(): Promise<{ width: number; height: number }> {
  store.exporting = true;
  store.palette = applyPalette(store.settings.theme, false);
  document.documentElement.classList.add("exporting");
  store.emit();
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  await new Promise((r) => setTimeout(r, 120));
  const doc = document.querySelector(".report-doc") as HTMLElement | null;
  const width = Math.ceil((doc?.scrollWidth ?? 1040) + 64);
  const height = Math.ceil((doc?.scrollHeight ?? 1400) + 64);
  let style = document.getElementById("page-size");
  if (!style) {
    style = document.createElement("style");
    style.id = "page-size";
    document.head.appendChild(style);
  }
  style.textContent = `@page { size: ${width}px ${height}px; margin: 0; }`;
  return { width, height };
}

export function finishExport(): void {
  store.exporting = false;
  document.documentElement.classList.remove("exporting");
  store.applyTheme();
  store.emit();
}

/** The visual report for the selected period. Shown on the Reports screen and rendered to PDF. */
export function ReportDocument() {
  const s = useStore();
  const forExport = s.exporting;
  const events = s.periodEvents;
  const summary = UsageSummary.of(events);
  const previousEvents = s.previousPeriodEvents;
  const previous = previousEvents ? UsageSummary.of(previousEvents) : undefined;
  const sessions = sessionSummaries(events);
  const previousSessions = previousEvents ? new Set(previousEvents.map((e) => e.event.sessionID)).size : undefined;
  const interval = s.periodInterval();
  const unit = s.periodChartUnit;
  const days = interval ? daily(events, interval) : [];
  const cells = Analytics.heatmap(events);

  return (
    <div class="report-doc">
      <ReportCover summary={summary} previous={previous} />
      {summary.requests === 0 ? (
        <Card title="Нет данных"><div class="secondary">За выбранный период запросов не было. Выберите другой период вверху окна.</div></Card>
      ) : (
        <>
          <KPIRow summary={summary} previous={previous} sessions={sessions.length} previousSessions={previousSessions} />
          {interval ? (
            <Card title={`Расход ${unitTitle(unit)}`} subtitle={`${s.costLabel}, по моделям`}>
              <CostTimelineChart buckets={Analytics.buckets(events, unit, interval, (e) => s.seriesName(e))} unit={unit} interval={interval} />
            </Card>
          ) : null}
          <div class="row top gap-16">
            <Card title="Из чего складывается стоимость" class="grow basis0"><CostComposition summary={summary} /></Card>
            <Card title="Модели" subtitle="доля расхода" class="grow basis0"><RankedBarList rows={modelRows(events, summary.totalCost)} labelWidth={120} /></Card>
          </div>
          <div class="row top gap-16">
            <Card title="Проекты" subtitle="по расходу" class="grow basis0"><RankedBarList rows={projectRows(events, summary.totalCost)} labelWidth={170} /></Card>
            <Card title="Самые дорогие сессии" class="grow basis0"><RankedBarList rows={sessionRows(sessions)} labelWidth={230} /></Card>
          </div>
          {days.length >= 2 ? (
            <div class="row top gap-16">
              <Card title="Доля контекста из кэша" subtitle="по дням" class="grow basis0">
                <DailyMetricChart points={days.map((d) => ({ day: d.day, value: d.cacheRate }))} max={1} format={(v) => Fmt.percent(v)} />
              </Card>
              <Card title="Средний размер контекста" subtitle="токенов на запрос, по дням" class="grow basis0">
                <DailyMetricChart points={days.map((d) => ({ day: d.day, value: d.context }))} max={Math.max(...days.map((d) => d.context)) * 1.15} format={(v) => Fmt.tokens(Math.trunc(v))} />
              </Card>
            </div>
          ) : null}
          <Card title="Когда вы работаете" subtitle={`${s.costLabel} по дням недели и часам`}>
            <div class="stack-8">
              <ActivityHeatmap cells={cells} showsHint={!forExport} />
              <div class="callout secondary">{rhythm(cells, summary.totalCost)}</div>
            </div>
          </Card>
          <ReportInsights events={events} />
        </>
      )}
      <ReportFooter />
    </div>
  );
}

function modelRows(events: PricedEvent[], total: number): RankedRow[] {
  const s = store;
  const groups = Analytics.group(events, (e) => s.seriesName(e));
  const scale = s.colorScale(groups.map((g) => g.key));
  return groups.map((g) => ({
    id: g.key,
    label: g.key,
    detail: Fmt.plural(g.summary.requests, "запрос", "запроса", "запросов"),
    value: g.summary.totalCost,
    valueText: `${Fmt.usd(g.summary.totalCost)} · ${Fmt.percent(g.summary.totalCost / Math.max(total, Number.MIN_VALUE))}`,
    color: scale.range[scale.domain.indexOf(g.key)] ?? s.palette.other,
  }));
}

function projectRows(events: PricedEvent[], total: number): RankedRow[] {
  const groups = Analytics.group(events, (e) => projectName(e.projectPath));
  const share = (cost: number) => Fmt.percent(cost / Math.max(total, Number.MIN_VALUE));
  const rows: RankedRow[] = groups.slice(0, 7).map((g) => ({
    id: g.key,
    label: g.key,
    detail: `${Fmt.plural(g.summary.requests, "запрос", "запроса", "запросов")} · кэш ${Fmt.percent(g.summary.cacheHitRate)}`,
    value: g.summary.totalCost,
    valueText: `${Fmt.usd(g.summary.totalCost)} · ${share(g.summary.totalCost)}`,
  }));
  const rest = groups.slice(7);
  if (rest.length) {
    const cost = rest.reduce((a, g) => a + g.summary.totalCost, 0);
    rows.push({ id: "__other", label: `Другие (${rest.length})`, value: cost, valueText: `${Fmt.usd(cost)} · ${share(cost)}`, color: C.other });
  }
  return rows;
}

function sessionRows(sessions: SessionSummary[]): RankedRow[] {
  return [...sessions].sort((a, b) => b.summary.totalCost - a.summary.totalCost).slice(0, 6).map((x) => ({
    id: x.id,
    label: `${sessionProject(x)} · ${Fmt.dateTime(x.start)}`,
    detail: `${Fmt.plural(x.summary.requests, "запрос", "запроса", "запросов")} · пик контекста ${Fmt.tokens(x.peakContextTokens)} · ${Fmt.duration((x.end - x.start) / 1000)}`,
    value: x.summary.totalCost,
    valueText: Fmt.usd(x.summary.totalCost),
  }));
}

interface Day {
  day: number;
  cacheRate: number;
  context: number;
}

/** Days of the period that had requests: cache share and average context. */
function daily(events: PricedEvent[], interval: Interval): Day[] {
  return Analytics.buckets(events, "day", interval, () => "all")
    .filter((b) => b.summary.requests > 0)
    .map((b) => ({ day: b.start, cacheRate: b.summary.cacheHitRate, context: b.summary.averageContextTokens }));
}

const DAY_DATIVE = ["понедельникам", "вторникам", "средам", "четвергам", "пятницам", "субботам", "воскресеньям"];

/** "Больше всего расходуется по средам (34%), пиковый час — 14:00–15:00." */
function rhythm(cells: HeatCell[], total: number): string {
  if (total <= 0) return "";
  const byDay = new Array(7).fill(0);
  const byHour = new Array(24).fill(0);
  for (const cell of cells) {
    byDay[cell.weekday] += cell.cost;
    byHour[cell.hour] += cell.cost;
  }
  const day = byDay.indexOf(Math.max(...byDay));
  const hour = byHour.indexOf(Math.max(...byHour));
  const hh = (h: number) => String(h).padStart(2, "0");
  return `Больше всего расходуется по ${DAY_DATIVE[day]} (${Fmt.percent(byDay[day] / total)}), пиковый час — ${hh(hour)}:00–${hh((hour + 1) % 24)}:00.`;
}

const change = (current: number, previous: number): number | undefined => (previous > 0 ? (current - previous) / previous : undefined);

/** Brand band with the period and the one hero number. */
function ReportCover({ summary, previous }: { summary: UsageSummary; previous?: UsageSummary }) {
  const s = useStore();
  const interval = s.periodInterval();
  const parts: string[] = [];
  if (interval) parts.push(`${Fmt.day(interval.start)} – ${Fmt.day(interval.end - 1)}`);
  parts.push(PERIODS.find((p) => p.id === s.period)!.title);
  if (s.isSubscription) parts.push(`подписка ${s.planTitle}`);
  const delta = previous ? change(summary.totalCost, previous.totalCost) : undefined;
  return (
    <div class="report-cover">
      <div class="stack-10">
        <div class="row gap-8">
          <span class="cover-mark"><Icon icon={I.Activity} size={16} /></span>
          <strong>S2A Claude X-Ray</strong>
        </div>
        <div class="cover-title">Отчёт об использовании Claude Code</div>
        <div class="callout cover-dim">{parts.join(" · ")}</div>
      </div>
      <span class="spacer" />
      <div class="right-col stack-4 cover-right">
        <div class="cover-hero num">{Fmt.usd(summary.totalCost)}</div>
        <div class="callout cover-dim">{s.costLabel}</div>
        {delta !== undefined ? (
          <span class="cover-pill">
            <Icon icon={delta >= 0 ? I.ArrowUpRight : I.ArrowDownRight} size={14} />
            {`${delta >= 0 ? "+" : "−"}${Fmt.percent(Math.abs(delta))} к прошлому периоду`}
          </span>
        ) : null}
      </div>
    </div>
  );
}

/** Headline numbers with the change against the previous period of the same length. */
function KPIRow({ summary, previous, sessions, previousSessions }: { summary: UsageSummary; previous?: UsageSummary; sessions: number; previousSessions?: number }) {
  const perSession = sessions > 0 ? summary.totalCost / sessions : 0;
  const previousPerSession = previous && previousSessions ? previous.totalCost / previousSessions : undefined;
  return (
    <div class="tiles">
      <ReportStat title="Токены" value={Fmt.tokens(summary.totalTokens)} change={previous ? change(summary.totalTokens, previous.totalTokens) : undefined} />
      <ReportStat title="Запросы" value={String(summary.requests)} change={previous ? change(summary.requests, previous.requests) : undefined} />
      <ReportStat title="Сессии" value={String(sessions)} change={previousSessions !== undefined ? change(sessions, previousSessions) : undefined} />
      <ReportStat
        title="Доля кэша"
        value={Fmt.percent(summary.cacheHitRate)}
        change={previous && previous.requests > 0 ? summary.cacheHitRate - previous.cacheHitRate : undefined}
        points
        upIsGood
      />
      <ReportStat title="Средняя сессия" value={Fmt.usd(perSession)} change={previousPerSession !== undefined ? change(perSession, previousPerSession) : undefined} upIsGood={false} />
    </div>
  );
}

/** Stat tile with a signed change; the color says whether the change is good, when that is known. */
function ReportStat({ title, value, change, points, upIsGood }: { title: string; value: string; change?: number; points?: boolean; upIsGood?: boolean }) {
  let note;
  if (change !== undefined && Math.abs(change) >= 0.0005) {
    const sign = change > 0 ? "+" : "−";
    const text = points
      ? `${sign}${(Math.abs(change) * 100).toFixed(1).replace(".", ",")} п.п. к прошлому периоду`
      : `${sign}${Fmt.percent(Math.abs(change))} к прошлому периоду`;
    const color = upIsGood === undefined ? "var(--text2)" : (change > 0) === upIsGood ? C.good : C.critical;
    note = (
      <span class="label caption strong" style={{ color }}>
        <Icon icon={change > 0 ? I.ArrowUpRight : I.ArrowDownRight} size={13} />
        <span>{text}</span>
      </span>
    );
  } else {
    note = <span class="caption secondary">{change === undefined ? "нет данных для сравнения" : "без изменений"}</span>;
  }
  return (
    <div class="tile">
      <div class="tile-title"><span>{title}</span></div>
      <div class="tile-value report num">{value}</div>
      {note}
    </div>
  );
}

/** One measure per day: a 2 px line over a light wash, the latest value labelled. */
function DailyMetricChart({ points, max, format }: { points: { day: number; value: number }[]; max: number; format: (v: number) => string }) {
  const p = store.palette;
  const color = p.roles.model;
  const option = useMemo<ChartOption>(() => {
    const last = points[points.length - 1];
    return {
      ...baseOption(p),
      grid: { left: 4, right: 18, top: 26, bottom: 4, containLabel: true },
      tooltip: {
        ...tooltipBase(p),
        trigger: "axis",
        axisPointer: { type: "line", lineStyle: { color: p.other, opacity: 0.55 } },
        formatter: (params: unknown) => {
          const list = (Array.isArray(params) ? params : [params]) as { value: [number, number] }[];
          return list.length ? tooltipHTML(Fmt.day(list[0].value[0]), [{ label: "Значение", value: format(list[0].value[1]), color }]) : "";
        },
      },
      xAxis: {
        type: "time",
        ...axis(p),
        splitNumber: 6,
        axisLabel: { ...axis(p).axisLabel, formatter: (v: number) => { const d = new Date(v); return `${String(d.getDate()).padStart(2, "0")}.${String(d.getMonth() + 1).padStart(2, "0")}`; } },
      },
      yAxis: { type: "value", min: 0, max, splitNumber: 4, ...axis(p), axisLabel: { ...axis(p).axisLabel, formatter: (v: number) => format(v) } },
      series: [{
        type: "line",
        data: points.map((x) => [x.day, x.value]),
        smooth: 0.35,
        smoothMonotone: "x",
        showSymbol: false,
        lineStyle: { width: 2, color, cap: "round", join: "round" },
        areaStyle: { color, opacity: 0.1 },
        emphasis: { disabled: true },
        markPoint: last ? {
          symbol: "circle",
          symbolSize: 9,
          itemStyle: { color, borderColor: p.card, borderWidth: 3 },
          label: { show: true, position: "top", distance: 6, formatter: format(last.value), color: p.text, fontWeight: 600, fontSize: 11, fontFamily: FONT },
          data: [{ coord: [last.day, last.value] }],
        } : undefined,
      }],
    } as ChartOption;
  }, [points, max, p]);
  return <EChart option={option} height={170} />;
}

/** Recommendations, the ones that keep quality first, with the savings they promise. */
function ReportInsights({ events }: { events: PricedEvent[] }) {
  const s = useStore();
  const insights = analyzeInsights(s.pricing, events);
  const free = insights.filter((i) => i.kind === "freeWin").reduce((a, i) => a + (i.potentialSavings ?? 0), 0);
  return (
    <Card title="Рекомендации" subtitle={free > 0 ? `без потери качества можно сэкономить до ${Fmt.usd(free)}` : undefined}>
      {insights.length === 0 ? <div class="secondary">Замечаний нет: расход выглядит сбалансированным.</div> : (
        <div class="stack-12">{insights.map((i) => <InsightCard key={i.id} insight={i} />)}</div>
      )}
    </Card>
  );
}

function ReportFooter() {
  const s = useStore();
  const parts = ["Суммы — API-эквивалент по прайс-листу Anthropic"];
  if (s.isSubscription) parts[0] += `: на подписке ${s.planTitle} деньги не списываются`;
  parts.push("Источники: логи Claude Code на этом компьютере, импортированные логи и логи, присланные облачными сессиями");
  parts.push(`Сформировано ${Fmt.dateTime(s.now)} в S2A Claude X-Ray`);
  return <div class="caption secondary">{parts.join(". ") + "."}</div>;
}

