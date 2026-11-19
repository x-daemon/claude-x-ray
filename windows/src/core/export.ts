// CSV and Markdown reports. Port of XRayCore/Export/ReportExporter.swift.
import { Analytics, sessionModelsLabel, sessionProject, sessionSummaries, UsageSummary, type GroupSummary, type SessionSummary } from "./analytics";
import { Fmt } from "./fmt";
import { kindLabel, severityLabel, type Insight } from "./insights";
import { cacheHitRate, cacheWrite, displayModelName, projectName, totalTokens } from "./model";
import { type PricedEvent } from "./pricing";
import { L } from "./i18n";

export function csvField(value: string): string {
  return /[",\n]/.test(value) ? `"${value.replace(/"/g, '""')}"` : value;
}

export function dailyCSV(events: PricedEvent[]): string {
  const rows = new Map<string, Map<string, UsageSummary>>();
  for (const priced of events) {
    const day = Fmt.isoDay(priced.event.timestamp);
    let byModel = rows.get(day);
    if (!byModel) rows.set(day, (byModel = new Map()));
    let s = byModel.get(priced.event.model);
    if (!s) byModel.set(priced.event.model, (s = new UsageSummary()));
    s.add(priced);
  }
  const lines = [
    "date,model,requests,input_tokens,output_tokens,thinking_tokens,cache_read_tokens,cache_write_5m_tokens,cache_write_1h_tokens,cache_hit_rate,api_equivalent_usd",
  ];
  for (const day of [...rows.keys()].sort()) {
    for (const [model, s] of [...rows.get(day)!.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
      lines.push([
        day, csvField(model), `${s.requests}`,
        `${s.tokens.input}`, `${s.tokens.output}`, `${s.tokens.thinking}`,
        `${s.tokens.cacheRead}`, `${s.tokens.cacheWrite5m}`, `${s.tokens.cacheWrite1h}`,
        Fmt.decimal(cacheHitRate(s.tokens)), Fmt.decimal(s.totalCost),
      ].join(","));
    }
  }
  return lines.join("\n") + "\n";
}

export function sessionsCSV(sessions: SessionSummary[]): string {
  const lines = [
    "session_id,project,git_branch,start,end,duration_min,models,requests,total_tokens,peak_context_tokens,cache_hit_rate,subagent_usd,api_equivalent_usd",
  ];
  const iso = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
  for (const s of sessions) {
    lines.push([
      csvField(s.id), csvField(s.projectPath), csvField(s.gitBranch ?? ""),
      iso(s.start), iso(s.end),
      Fmt.decimal((s.end - s.start) / 60_000, 1),
      csvField(s.models.join(" ")),
      `${s.summary.requests}`, `${s.summary.totalTokens}`, `${s.peakContextTokens}`,
      Fmt.decimal(s.summary.cacheHitRate), Fmt.decimal(s.sidechainCost), Fmt.decimal(s.summary.totalCost),
    ].join(","));
  }
  return lines.join("\n") + "\n";
}

function groupTable(groups: GroupSummary[], total: number, name: (key: string) => string): string {
  const lines = [L`| Название | Запросы | Токены | Кэш | USD | Доля |`, "|---|---|---|---|---|---|"];
  for (const g of groups) {
    lines.push(`| ${name(g.key)} | ${g.summary.requests} | ${Fmt.tokens(g.summary.totalTokens)} | ${Fmt.percent(g.summary.cacheHitRate)} | ${Fmt.usd(g.summary.totalCost)} | ${Fmt.percent(g.summary.totalCost / total)} |`);
  }
  return lines.join("\n") + "\n";
}

export function markdownReport(title: string, periodLabel: string, events: PricedEvent[], insights: Insight[], generatedAt = Date.now()): string {
  const summary = UsageSummary.of(events);
  const byModel = Analytics.group(events, (e) => e.model);
  const byProject = Analytics.group(events, (e) => projectName(e.projectPath));
  const sessions = sessionSummaries(events);
  const t = summary.tokens;
  const md: string[] = [];
  md.push(`# ${title}`, "", L`Период: **${periodLabel}** · сформирован ${Fmt.dateTime(generatedAt)}`, "");
  md.push(L`> Суммы — API-эквивалент по прайс-листу. На подписке Pro/Max они не списываются, но показывают, как быстро расходуются лимиты.`, "");
  md.push(L`## Итого`, "", L`| Показатель | Значение |`, "|---|---|");
  md.push(L`| API-эквивалент | ${Fmt.usd(summary.totalCost)} |`);
  md.push(L`| Запросов | ${summary.requests} |`);
  md.push(L`| Сессий | ${sessions.length} |`);
  md.push(L`| Токенов всего | ${Fmt.tokens(totalTokens(t))} |`);
  md.push(L`| Ввод / вывод | ${Fmt.tokens(t.input)} / ${Fmt.tokens(t.output)} |`);
  md.push(L`| Размышления (в выводе) | ${Fmt.tokens(t.thinking)} |`);
  md.push(L`| Чтение кэша / запись | ${Fmt.tokens(t.cacheRead)} / ${Fmt.tokens(cacheWrite(t))} |`);
  md.push(L`| Доля попаданий в кэш | ${Fmt.percent(cacheHitRate(t))} |`, "");
  md.push(L`### Из чего складывается стоимость`, "", L`| Статья | USD | Доля |`, "|---|---|---|");
  const total = Math.max(summary.totalCost, Number.MIN_VALUE);
  for (const [name, value] of [
    [L`Ввод`, summary.cost.input], [L`Вывод`, summary.cost.output],
    [L`Чтение кэша`, summary.cost.cacheRead], [L`Запись в кэш`, summary.cost.cacheWrite],
    [L`Веб-поиск`, summary.cost.webSearch],
  ] as const) {
    if (value > 0) md.push(`| ${name} | ${Fmt.usd(value)} | ${Fmt.percent(value / total)} |`);
  }
  md.push("", L`## По моделям`, "", groupTable(byModel, total, displayModelName));
  md.push(L`## По проектам`, "", groupTable(byProject.slice(0, 15), total, (k) => k));
  md.push(L`## Самые дорогие сессии`, "", L`| Начало | Проект | Модели | Запросы | Пик контекста | USD |`, "|---|---|---|---|---|---|");
  for (const s of sessions.slice(0, 10)) {
    md.push(`| ${Fmt.dateTime(s.start)} | ${sessionProject(s)} | ${sessionModelsLabel(s)} | ${s.summary.requests} | ${Fmt.tokens(s.peakContextTokens)} | ${Fmt.usd(s.summary.totalCost)} |`);
  }
  md.push("", L`## Оптимизация`, "");
  if (!insights.length) md.push(L`Замечаний нет.`);
  for (const insight of insights) {
    let heading = `### ${severityLabel[insight.severity]}: ${insight.title}`;
    if (insight.potentialSavings && insight.potentialSavings > 0) heading += L` (до ${Fmt.usd(insight.potentialSavings)})`;
    md.push(heading, "", `_${kindLabel[insight.kind]}._ ${insight.detail}`);
    if (insight.recommendation) md.push("", L`**Что сделать:** ${insight.recommendation}`);
    md.push("");
  }
  md.push("---", "S2A Claude X-Ray");
  return md.join("\n") + "\n";
}
