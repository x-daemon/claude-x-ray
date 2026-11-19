// "Сессии": sortable table of sessions with a detail pane for the selected one.
// Port of Views/SessionsView.swift.
import { useMemo, useState } from "preact/hooks";
import { sessionModelsLabel, sessionProject, sessionSummaries, type SessionSummary } from "../../core/analytics";
import { Fmt } from "../../core/fmt";
import { contextTokens } from "../../core/model";
import { costTotal, type PricedEvent } from "../../core/pricing";
import { axis, baseOption, EChart, tokenAxisLabel, tooltipBase, tooltipHTML, usdAxisLabel, type ChartOption } from "../chart";
import * as I from "../icons";
import { store, useStore } from "../state";
import { C } from "../traceStyle";
import { Card, Icon, Legend, StatTile, Tiles } from "../ui";
import { L, N, titled } from "../../core/i18n";

type SortKey = "start" | "project" | "duration" | "requests" | "peak" | "cache" | "cost";

const COLUMNS: { title: string; key?: SortKey; numeric?: boolean }[] = titled([
  { title: N("Начало"), key: "start" },
  { title: N("Проект"), key: "project" },
  { title: N("Ветка") },
  { title: N("Модели") },
  { title: N("Длительность"), key: "duration", numeric: true },
  { title: N("Запросы"), key: "requests", numeric: true },
  { title: N("Пик контекста"), key: "peak", numeric: true },
  { title: N("Кэш"), key: "cache", numeric: true },
  { title: "USD", key: "cost", numeric: true },
]);

function sortValue(s: SessionSummary, key: SortKey): number | string {
  switch (key) {
    case "start": return s.start;
    case "project": return sessionProject(s).toLocaleLowerCase();
    case "duration": return s.end - s.start;
    case "requests": return s.summary.requests;
    case "peak": return s.peakContextTokens;
    case "cache": return s.summary.cacheHitRate;
    case "cost": return s.summary.totalCost;
  }
}

export function SessionsView() {
  const s = useStore();
  const [sort, setSort] = useState<{ key: SortKey; desc: boolean }>({ key: "cost", desc: true });
  const [query, setQuery] = useState("");
  const events = s.periodEvents;
  const sessions = useMemo(() => sessionSummaries(events), [events]);
  const needle = query.trim().toLocaleLowerCase();
  const rows = sessions
    .filter((x) => !needle || x.projectPath.toLocaleLowerCase().includes(needle) || (x.gitBranch ?? "").toLocaleLowerCase().includes(needle) || sessionModelsLabel(x).toLocaleLowerCase().includes(needle))
    .sort((a, b) => {
      const x = sortValue(a, sort.key);
      const y = sortValue(b, sort.key);
      const order = x < y ? -1 : x > y ? 1 : 0;
      return sort.desc ? -order : order;
    });
  const selected = sessions.find((x) => x.id === s.selectedSession);
  const sortBy = (key: SortKey) => setSort(sort.key === key ? { key, desc: !sort.desc } : { key, desc: key !== "project" });

  return (
    <div class="split-view">
      <div class="split-top">
        <div class="row gap-12 toolbar-row">
          <input class="search" type="search" placeholder={L`Проект, ветка или модель`} value={query} onInput={(e) => setQuery((e.currentTarget as HTMLInputElement).value)} />
          <span class="spacer" />
          <span class="caption secondary">{Fmt.plural(rows.length, "сессия", "сессии", "сессий")}</span>
        </div>
        <div class="table-wrap scroll">
          <table class="table sticky">
            <thead>
              <tr>
                {COLUMNS.map((col) => (
                  <th
                    key={col.title}
                    class={[col.numeric ? "right" : "", col.key ? "sortable" : ""].join(" ")}
                    onClick={col.key ? () => sortBy(col.key!) : undefined}
                  >
                    {col.title}
                    {col.key === sort.key ? <span class="sort-mark">{sort.desc ? "▼" : "▲"}</span> : null}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((x) => (
                <tr key={x.id} class={x.id === s.selectedSession ? "clickable selected" : "clickable"} onClick={() => store.set("selectedSession", x.id)}>
                  <td class="num">{Fmt.dateTime(x.start)}</td>
                  <td class="ellipsis" title={x.projectPath}>{sessionProject(x)}</td>
                  <td class="secondary">{x.gitBranch ?? "—"}</td>
                  <td>{sessionModelsLabel(x)}</td>
                  <td class="right num">{Fmt.duration((x.end - x.start) / 1000)}</td>
                  <td class="right num">{x.summary.requests}</td>
                  <td class="right num">{Fmt.tokens(x.peakContextTokens)}</td>
                  <td class="right num">{Fmt.percent(x.summary.cacheHitRate)}</td>
                  <td class="right num">{Fmt.usd(x.summary.totalCost)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {rows.length === 0 ? <div class="empty-note secondary">{L`Сессий за период нет`}</div> : null}
        </div>
      </div>
      <div class="split-bottom" data-scroll>
        {selected ? (
          <SessionDetail session={selected} events={events.filter((e) => e.event.sessionID === selected.id)} />
        ) : (
          <div class="unavailable">
            <Icon icon={I.Rows3} size={32} class="secondary light" />
            <h3>{L`Выберите сессию`}</h3>
            <div class="secondary">{L`Детали, рост контекста и стоимость каждого запроса.`}</div>
          </div>
        )}
      </div>
    </div>
  );
}

function SessionDetail({ session, events }: { session: SessionSummary; events: PricedEvent[] }) {
  const p = store.palette;
  const cost = session.summary.totalCost;
  const main = events.filter((e) => !e.event.isSidechain);
  const side = events.filter((e) => e.event.isSidechain);

  const contextOption = useMemo<ChartOption>(() => {
    const line = (name: string, color: string, data: PricedEvent[]) => ({
      type: "line" as const,
      name,
      data: data.map((e) => [e.event.timestamp, contextTokens(e.event.tokens)]),
      lineStyle: { width: 2, color },
      itemStyle: { color },
      showSymbol: false,
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
          return list.length ? tooltipHTML(Fmt.time(list[0].value[0]), list.map((x) => ({ label: x.seriesName, value: Fmt.tokens(x.value[1]), color: x.color }))) : "";
        },
      },
      xAxis: { type: "time", ...axis(p), axisLabel: { ...axis(p).axisLabel, formatter: (v: number) => Fmt.time(v, false) } },
      yAxis: { type: "value", ...axis(p), axisLabel: { ...axis(p).axisLabel, formatter: tokenAxisLabel } },
      series: [line(L`Основная сессия`, p.roles.model, main), ...(side.length ? [line(L`Субагент`, p.roles.subagent, side)] : [])],
    };
  }, [events, p]);

  const costOption = useMemo<ChartOption>(() => {
    const bar = (name: string, color: string, value: (e: PricedEvent) => number, top: boolean) => ({
      type: "bar" as const,
      name,
      stack: "cost",
      barWidth: 4,
      itemStyle: { color, borderRadius: top ? [2, 2, 0, 0] : 0 },
      emphasis: { disabled: true },
      data: events.map((e) => [e.event.timestamp, value(e)]),
    });
    return {
      ...baseOption(p),
      tooltip: {
        ...tooltipBase(p),
        trigger: "axis",
        axisPointer: { type: "line", lineStyle: { color: p.other, opacity: 0.55 } },
        formatter: (params: unknown) => {
          const list = (Array.isArray(params) ? params : [params]) as { seriesName: string; value: [number, number]; color: string }[];
          return list.length ? tooltipHTML(Fmt.time(list[0].value[0]), list.map((x) => ({ label: x.seriesName, value: Fmt.usd(x.value[1]), color: x.color }))) : "";
        },
      },
      xAxis: { type: "time", ...axis(p), axisLabel: { ...axis(p).axisLabel, formatter: (v: number) => Fmt.time(v, false) } },
      yAxis: { type: "value", ...axis(p), axisLabel: { ...axis(p).axisLabel, formatter: usdAxisLabel } },
      series: [
        bar(L`Остальное`, p.roles.model, (e) => costTotal(e.cost) - e.cost.cacheWrite, false),
        bar(L`Запись в кэш`, p.series[3], (e) => e.cost.cacheWrite, true),
      ],
    };
  }, [events, p]);

  return (
    <div class="page">
      <div class="row baseline">
        <h3 class="selectable ellipsis">{session.projectPath}</h3>
        <span class="spacer" />
        <span class="secondary nowrap">{Fmt.dateTime(session.start)} – {Fmt.dateTime(session.end)}</span>
      </div>
      <Tiles>
        <StatTile title={L`Стоимость`} value={Fmt.usd(cost)} caption={L`${Fmt.usd(session.summary.costPerRequest)} за запрос`} />
        <StatTile title={L`Токены`} value={Fmt.tokens(session.summary.totalTokens)} caption={L`вывод ${Fmt.tokens(session.summary.tokens.output)}`} />
        <StatTile title={L`Пик контекста`} value={Fmt.tokens(session.peakContextTokens)} caption={L`средний ${Fmt.tokens(Math.trunc(session.summary.averageContextTokens))}`} />
        <StatTile title={L`Кэш`} value={Fmt.percent(session.summary.cacheHitRate)} caption={L`запись ${Fmt.usd(session.summary.cost.cacheWrite)}`} />
        <StatTile title={L`Субагенты`} value={Fmt.usd(session.sidechainCost)} caption={cost > 0 ? L`${Fmt.percent(session.sidechainCost / cost)} стоимости` : undefined} />
      </Tiles>
      <Card title={L`Рост контекста`} subtitle={L`токенов в промпте на каждый запрос`}>
        <EChart option={contextOption} height={170} label={L`Рост контекста`} />
        {side.length ? <Legend items={[{ name: L`Основная сессия`, color: C.model }, { name: L`Субагент`, color: C.subagent }]} /> : null}
      </Card>
      <Card title={L`Стоимость запросов`} subtitle={L`запись в кэш выделена отдельно`}>
        <EChart option={costOption} height={150} label={L`Стоимость запросов`} />
        <Legend items={[{ name: L`Остальное`, color: C.model }, { name: L`Запись в кэш`, color: p.series[3] }]} />
      </Card>
    </div>
  );
}
