// "Проекты" and "Модели": a ranked bar chart and a sortable table.
// Port of Views/BreakdownView.swift.
import { useState } from "preact/hooks";
import { Analytics } from "../../core/analytics";
import { Fmt } from "../../core/fmt";
import { displayModelName, type UsageEvent } from "../../core/model";
import { OTHER_SERIES, PERIODS, useStore } from "../state";
import { C } from "../traceStyle";
import { Card, RankedBarList } from "../ui";

export type Dimension = "project" | "model";

interface Row {
  id: string;
  name: string;
  detail: string;
  requests: number;
  tokens: number;
  cacheHitRate: number;
  thinkingShare: number;
  cost: number;
  share: number;
}

type SortKey = "name" | "requests" | "tokens" | "cacheHitRate" | "thinkingShare" | "cost" | "share";

const key = (dimension: Dimension) => (e: UsageEvent): string => (dimension === "project" ? e.projectPath : e.model);

/** Last `count` path components (both separators). */
const lastParts = (path: string, count: number): string => path.split(/[\\/]/).filter(Boolean).slice(-count).join("\\");

/** Display names; projects with the same folder name get their parent folder added. */
function displayNames(dimension: Dimension, keys: string[]): Map<string, string> {
  const result = new Map<string, string>();
  if (dimension === "model") {
    for (const k of keys) if (!result.has(k)) result.set(k, displayModelName(k));
    return result;
  }
  const short = keys.map((k) => lastParts(k, 1));
  const counts = new Map<string, number>();
  for (const name of short) counts.set(name, (counts.get(name) ?? 0) + 1);
  keys.forEach((k, i) => {
    const candidate = (counts.get(short[i]) ?? 0) > 1 ? lastParts(k, 2) : short[i];
    result.set(k, candidate || k);
  });
  return result;
}

export function BreakdownView({ dimension }: { dimension: Dimension }) {
  const s = useStore();
  const [sort, setSort] = useState<{ key: SortKey; desc: boolean }>({ key: "cost", desc: true });
  const events = s.periodEvents;
  const groups = Analytics.group(events, key(dimension));
  const total = Math.max(groups.reduce((a, g) => a + g.summary.totalCost, 0), Number.MIN_VALUE);
  const names = displayNames(dimension, groups.map((g) => g.key));
  const rows: Row[] = groups.map((g) => {
    const t = g.summary.tokens;
    return {
      id: g.key,
      name: names.get(g.key) ?? g.key,
      detail: g.key,
      requests: g.summary.requests,
      tokens: g.summary.totalTokens,
      cacheHitRate: g.summary.cacheHitRate,
      thinkingShare: t.output > 0 ? t.thinking / t.output : 0,
      cost: g.summary.totalCost,
      share: g.summary.totalCost / total,
    };
  });
  const top = [...rows].sort((a, b) => b.cost - a.cost).slice(0, 10);
  const scale = s.colorScale([...top.map((r) => r.name), OTHER_SERIES]);
  const color = (name: string) => {
    if (dimension !== "model") return C.model;
    const index = scale.domain.indexOf(name);
    return index >= 0 ? scale.range[index] : s.palette.other;
  };
  const sorted = [...rows].sort((a, b) => {
    const x = a[sort.key];
    const y = b[sort.key];
    const order = typeof x === "string" ? x.localeCompare(y as string, "ru") : (x as number) - (y as number);
    return sort.desc ? -order : order;
  });
  const columns: { title: string; key: SortKey; numeric?: boolean }[] = [
    { title: dimension === "project" ? "Проект" : "Модель", key: "name" },
    { title: "Запросы", key: "requests", numeric: true },
    { title: "Токены", key: "tokens", numeric: true },
    { title: "Кэш", key: "cacheHitRate", numeric: true },
    { title: "Размышления", key: "thinkingShare", numeric: true },
    { title: "USD", key: "cost", numeric: true },
    { title: "Доля", key: "share", numeric: true },
  ];
  const periodTitle = PERIODS.find((p) => p.id === s.period)!.title;

  return (
    <div class="page">
      <Card title={dimension === "project" ? "Самые дорогие проекты" : "Стоимость по моделям"} subtitle={`${s.costLabel} · ${periodTitle}`}>
        {top.length === 0 ? <div class="secondary empty-note" style={{ minHeight: "120px" }}>Нет данных за период</div> : (
          <RankedBarList rows={top.map((row) => ({
            id: row.id,
            label: row.name,
            detail: row.detail === row.name ? undefined : row.detail,
            value: row.cost,
            valueText: `${Fmt.usd(row.cost)} · ${Fmt.percent(row.share)}`,
            color: color(row.name),
          }))} />
        )}
      </Card>
      <div class="card flush">
        <div class="table-wrap">
          <table class="table">
            <thead>
              <tr>
                {columns.map((col) => (
                  <th key={col.key} class={(col.numeric ? "right " : "") + "sortable"} onClick={() => setSort(sort.key === col.key ? { key: col.key, desc: !sort.desc } : { key: col.key, desc: col.key !== "name" })}>
                    {col.title}
                    {col.key === sort.key ? <span class="sort-mark">{sort.desc ? "▼" : "▲"}</span> : null}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {sorted.map((row) => (
                <tr key={row.id}>
                  <td>
                    <div>{row.name}</div>
                    {row.detail !== row.name ? <div class="caption secondary ellipsis" title={row.detail}>{row.detail}</div> : null}
                  </td>
                  <td class="right num">{row.requests}</td>
                  <td class="right num">{Fmt.tokens(row.tokens)}</td>
                  <td class="right num">{Fmt.percent(row.cacheHitRate)}</td>
                  <td class="right num">{Fmt.percent(row.thinkingShare)}</td>
                  <td class="right num">{Fmt.usd(row.cost)}</td>
                  <td class="right num">{Fmt.percent(row.share)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
