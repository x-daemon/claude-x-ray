// Request-level health for a period: why the cache missed and what it cost, how answers ended,
// reasoning the API dropped, fallbacks. Used by "Оптимизация" and the report.
// Port of Views/RequestHealthView.swift.
import { Fmt } from "../../core/fmt";
import { cacheMissTitle, droppedReasonTitle, isRealMiss, requestIssues, stopReasonInfo } from "../../core/llm";
import type { PricedEvent } from "../../core/pricing";
import * as I from "../icons";
import { store } from "../state";
import { C } from "../traceStyle";
import { Card, Icon, RankedBarList } from "../ui";
import { toneColor } from "./traceLLM";
import { L } from "../../core/i18n";

/** Nothing to show for periods whose transcripts predate these fields. */
export function hasRequestDetails(events: PricedEvent[]): boolean {
  return events.some((e) => e.event.details?.stopReason || e.event.details?.cacheMiss);
}

export function RequestHealthCard({ events }: { events: PricedEvent[] }) {
  const issues = requestIssues(store.pricing, events);
  if (!hasRequestDetails(events)) return null;
  const missRows = issues.misses.map((g) => {
    const real = isRealMiss(g.reason);
    return {
      id: g.reason,
      label: cacheMissTitle(g.reason),
      detail: L`${Fmt.plural(g.count, "запрос", "запроса", "запросов")} · ${Fmt.tokens(g.missedTokens)} токенов${g.exact ? "" : L` записано`}`,
      value: real ? Math.max(g.extraCost, 0.0001) : 0.0001,
      valueText: real ? `≈${Fmt.usd(g.extraCost)}` : "—",
      color: real ? C.warning : C.other,
    };
  });
  const stopRows = [...issues.stopReasons.entries()].sort((a, b) => b[1] - a[1]).map(([reason, count]) => {
    const info = stopReasonInfo(reason);
    return {
      id: reason,
      label: info.title,
      detail: reason,
      value: count,
      valueText: `${count} · ${Fmt.percent(count / Math.max(issues.requests, 1))}`,
      color: info.tone === "good" ? C.model : info.tone === "info" ? C.tool : toneColor[info.tone],
    };
  });
  const facts: { icon: typeof I.Info; color: string; text: string }[] = [];
  if (issues.droppedRequests) {
    facts.push({
      icon: I.Brain, color: C.warning,
      text: L`API убирало размышления из истории в ${Fmt.plural(issues.droppedRequests, "запросе", "запросах", "запросах")}: ${issues.dropped.map((d) => `${droppedReasonTitle(d.reason)} (${d.blocks})`).join(", ")}`,
    });
  }
  if (issues.truncated) facts.push({ icon: I.TriangleExclamationPoint, color: C.warning, text: L`Обрезано лимитом вывода: ${Fmt.plural(issues.truncated, "ответ", "ответа", "ответов")}` });
  if (issues.refusals.size) facts.push({ icon: I.OctagonX, color: C.critical, text: L`Отказы: ${[...issues.refusals.entries()].map(([c, n]) => `${c} ${n}`).join(", ")}` });
  if (issues.fallbacks) facts.push({ icon: I.Layers, color: C.other, text: L`Ответов резервной модели: ${issues.fallbacks}` });
  if (issues.modelSwitches) facts.push({ icon: I.ArrowLeftRight, color: C.other, text: L`Ответила не та модель, что запрошена: ${Fmt.plural(issues.modelSwitches, "раз", "раза", "раз")}` });
  if (issues.contextEdits) facts.push({ icon: I.Minimize2, color: C.context, text: L`Сервер очищал контекст в ${Fmt.plural(issues.contextEdits, "запросе", "запросах", "запросах")}` });
  return (
    <Card
      title={L`Запросы к модели`}
      subtitle={issues.realMisses ? L`промахов кэша с причиной: ${issues.realMisses} · лишняя запись ≈${Fmt.usd(issues.realExtraCost)}` : L`по данным API в логах Claude Code`}
    >
      <div class="row top gap-16 wrap-narrow">
        <div class="stack-8 grow">
          <div class="caption strong secondary">{L`Почему не срабатывал кэш`}</div>
          {missRows.length ? <RankedBarList rows={missRows} labelWidth={260} /> : <div class="caption secondary">{L`Промахов кэша API не сообщало.`}</div>}
        </div>
        <div class="stack-8 grow">
          <div class="caption strong secondary">{L`Чем заканчивались ответы`}</div>
          {stopRows.length ? <RankedBarList rows={stopRows} labelWidth={190} /> : <div class="caption secondary">{L`Нет данных`}</div>}
        </div>
      </div>
      {facts.length ? (
        <div class="stack-4">
          {facts.map((f, i) => (
            <div class="row top gap-6 callout" key={i}>
              <Icon icon={f.icon} size={14} color={f.color} />
              <span>{f.text}</span>
            </div>
          ))}
        </div>
      ) : null}
      <div class="caption secondary">
        {L`Причины промахов кэша и потерянные размышления сообщает сам API (диагностика кэша, input_transformations); «не с чем сравнить» — первый запрос, пауза дольше TTL кэша или другой поток. Подробности по каждому запросу — в Live-трассе, вкладка «LLM-запросы».`}
      </div>
    </Card>
  );
}
