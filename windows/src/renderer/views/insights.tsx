// "Оптимизация": findings for the selected period. Port of Views/InsightsView.swift.
import { UsageSummary } from "../../core/analytics";
import { Fmt } from "../../core/fmt";
import { analyzeInsights, kindLabel, severityLabel, severityRank, type Insight } from "../../core/insights";
import * as I from "../icons";
import { PERIODS, useStore } from "../state";
import { severityColor, severityIcon } from "../traceStyle";
import { Icon, Label, StatTile, Tiles } from "../ui";
import { RequestHealthCard } from "./requestHealth";
import { L } from "../../core/i18n";

export function InsightsView() {
  const s = useStore();
  const events = s.periodEvents;
  const insights = analyzeInsights(s.pricing, events);
  const summary = UsageSummary.of(events);
  const sum = (kind: Insight["kind"]) => insights.filter((i) => i.kind === kind).reduce((a, i) => a + (i.potentialSavings ?? 0), 0);
  const free = sum("freeWin");
  const tradeoff = sum("tradeoff");
  const periodTitle = PERIODS.find((p) => p.id === s.period)!.title;
  return (
    <div class="page">
      <Tiles>
        <StatTile title={s.costLabel} value={Fmt.usd(summary.totalCost)} caption={periodTitle} />
        <StatTile title={L`Доля кэша`} value={summary.requests > 0 ? Fmt.percent(summary.cacheHitRate) : "—"} caption={L`чем выше, тем дешевле каждый ход`} />
        <StatTile
          title={L`Без потери качества`}
          value={free > 0 ? L`до ${Fmt.usd(free)}` : "—"}
          caption={tradeoff > 0 ? L`ещё до ${Fmt.usd(tradeoff)} через компромиссы; оценки пересекаются` : L`кэш и гигиена контекста`}
        />
        <StatTile
          title={L`Замечаний`}
          value={String(insights.filter((i) => severityRank[i.severity] >= severityRank.info).length)}
          caption={L`${insights.filter((i) => severityRank[i.severity] >= severityRank.warning).length} требуют внимания`}
        />
      </Tiles>
      {s.isSubscription ? (
        <Label icon={I.Info} class="callout secondary" text={L`На подписке экономия означает не деньги, а более медленный расход лимита 5-часового окна и недельного лимита.`} />
      ) : null}
      <RequestHealthCard events={events} />
      {insights.length === 0 ? (
        <div class="unavailable tall">
          <Icon icon={I.Lightbulb} size={32} class="secondary light" />
          <h3>{L`Нет данных для анализа`}</h3>
          <div class="secondary">{L`Выберите период, в котором были сессии Claude Code.`}</div>
        </div>
      ) : insights.map((insight) => <InsightCard key={insight.id} insight={insight} />)}
    </div>
  );
}

export function InsightCard({ insight }: { insight: Insight }) {
  const color = severityColor[insight.severity];
  return (
    <div class="card insight">
      <Icon icon={severityIcon[insight.severity]} size={24} color={color} />
      <div class="stack-8 grow min0">
        <div class="row baseline gap-8 wrap">
          <h3>{insight.title}</h3>
          <span class="badge" style={{ "--tint": color } as Record<string, string>}>{severityLabel[insight.severity]}</span>
          <span class="caption secondary">{kindLabel[insight.kind]}</span>
          <span class="spacer" />
          {insight.metric ? <span class="title3 strong num">{insight.metric}</span> : null}
        </div>
        <div>{insight.detail}</div>
        {insight.recommendation ? <div class="secondary">{insight.recommendation}</div> : null}
        {insight.potentialSavings && insight.potentialSavings > 0 ? (
          <Label icon={I.CircleArrowDown} class="callout strong good-text" text={L`Потенциальная экономия: до ${Fmt.usd(insight.potentialSavings)} за период`} />
        ) : null}
      </div>
    </div>
  );
}
