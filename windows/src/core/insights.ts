// Rule-based analysis of where tokens go and what would reduce them.
// Port of XRayCore/Insights/InsightEngine.swift. Dollar figures are API-equivalent list prices.
import { sessionProject, sessionSummaries, UsageSummary } from "./analytics";
import { Fmt } from "./fmt";
import { cacheWrite, contextTokens, isFastMode, isTopTier, modelFamily } from "./model";
import { cacheMissAdvice, cacheMissTitle, droppedReasonTitle, requestIssues } from "./llm";
import { costAsModel, costTotal, matchPrice, type ModelPrice, type PricedEvent, type PricingTable } from "./pricing";

export type InsightSeverity = "good" | "info" | "warning" | "critical";
export type InsightKind = "freeWin" | "tradeoff" | "observation";

export const severityRank: Record<InsightSeverity, number> = { good: 0, info: 1, warning: 2, critical: 3 };
export const severityLabel: Record<InsightSeverity, string> = { good: "Хорошо", info: "Совет", warning: "Внимание", critical: "Критично" };
export const kindLabel: Record<InsightKind, string> = { freeWin: "Без потери качества", tradeoff: "Компромисс", observation: "Наблюдение" };

export interface Insight {
  id: string;
  severity: InsightSeverity;
  kind: InsightKind;
  title: string;
  /** What the data shows. */
  detail: string;
  /** What to do about it. */
  recommendation?: string;
  /** Key figure, e.g. "38%". */
  metric?: string;
  /** API-equivalent USD that could be saved over the analysed period. */
  potentialSavings?: number;
}

export interface InsightOptions {
  largeContextThreshold?: number;
  rewarmMinimumContext?: number;
  cheaperModelPrefix?: string;
}

export function analyzeInsights(pricing: PricingTable, events: PricedEvent[], options: InsightOptions = {}): Insight[] {
  const largeContextThreshold = options.largeContextThreshold ?? 150_000;
  const rewarmMinimumContext = options.rewarmMinimumContext ?? 20_000;
  const cheaperModelPrefix = options.cheaperModelPrefix ?? "claude-sonnet-5-5";

  const summary = UsageSummary.of(events);
  const total = summary.totalCost;
  if (summary.requests === 0 || total <= 0) return [];
  const insights: Insight[] = [];

  // Cache efficiency.
  {
    const hit = summary.cacheHitRate;
    const metric = Fmt.percent(hit);
    if (hit >= 0.85) {
      insights.push({
        id: "cache.hit", severity: "good", kind: "observation",
        title: "Кэш промптов работает хорошо",
        detail: `${metric} контекста читается из кэша — это самый дешёвый вид входных токенов.`,
        metric,
      });
    } else {
      insights.push({
        id: "cache.hit", severity: hit < 0.6 ? "warning" : "info", kind: "freeWin",
        title: "Низкая доля попаданий в кэш",
        detail: `Из кэша читается только ${metric} контекста. Остальное оплачивается как свежий ввод или как запись в кэш, которая дороже ввода.`,
        recommendation: "Не меняйте модель и настройки посреди сессии, держите CLAUDE.md и системные инструкции стабильными, между задачами начинайте новую сессию (/clear), а не продолжайте старую с другим контекстом.",
        metric,
      });
    }
  }

  // Cache writes.
  {
    const share = summary.cost.cacheWrite / total;
    if (share >= 0.25) {
      const writes = cacheWrite(summary.tokens);
      const oneHourShare = writes > 0 ? summary.tokens.cacheWrite1h / writes : 0;
      let detail = `Запись в кэш — ${Fmt.percent(share)} стоимости (${Fmt.usd(summary.cost.cacheWrite)}).`;
      if (oneHourShare > 0.5) {
        detail += ` ${Fmt.percent(oneHourShare)} записей идут с TTL 1 час: такая запись стоит 2× цены ввода (TTL 5 минут — 1.25×), зато переживает паузы до часа.`;
      }
      insights.push({
        id: "cache.writes", severity: share >= 0.4 ? "warning" : "info", kind: "freeWin",
        title: "Много платите за запись в кэш",
        detail,
        recommendation: "Каждый раз, когда начало контекста меняется, весь контекст после изменения записывается в кэш заново. Сокращайте контекст (/compact), не переключайте модель внутри длинной сессии и начинайте новую задачу с /clear.",
        metric: Fmt.percent(share),
      });
    }
  }

  // Requests after an idle gap longer than the cache TTL that rewrote most of their context.
  {
    let count = 0;
    let cost = 0;
    let avoidable = 0;
    const previousBySession = new Map<string, PricedEvent>();
    const priceCache = new Map<string, ModelPrice | undefined>();
    for (const priced of [...events].sort((a, b) => a.event.timestamp - b.event.timestamp)) {
      const e = priced.event;
      const previous = previousBySession.get(e.sessionID);
      previousBySession.set(e.sessionID, priced);
      if (!previous) continue;
      const ttl = previous.event.tokens.cacheWrite1h > 0 ? 3_600_000 : 300_000;
      const gap = e.timestamp - previous.event.timestamp;
      const t = e.tokens;
      if (!(gap > ttl && contextTokens(t) >= rewarmMinimumContext && cacheWrite(t) >= 0.5 * contextTokens(t))) continue;
      count++;
      cost += priced.cost.cacheWrite;
      let price = priceCache.get(e.model);
      if (!priceCache.has(e.model)) {
        price = matchPrice(pricing, e.model).price;
        priceCache.set(e.model, price);
      }
      if (price) {
        // Had the cache still been warm, these tokens would have been reads.
        const writeCost = (t.cacheWrite5m * price.cacheWrite5m + t.cacheWrite1h * price.cacheWrite1h) / 1_000_000;
        const readCost = (cacheWrite(t) * price.cacheRead) / 1_000_000;
        avoidable += Math.max(0, writeCost - readCost);
      }
    }
    if (count >= 3 && cost / total >= 0.03) {
      insights.push({
        id: "cache.rewarm", severity: cost / total >= 0.1 ? "warning" : "info", kind: "freeWin",
        title: "Паузы обнуляют кэш",
        detail: `${count} раз после паузы длиннее срока жизни кэша весь контекст сессии записывался заново: ${Fmt.usd(cost)} за запись.`,
        recommendation: "Возвращаясь после перерыва к новой задаче, начинайте её с /clear. Если нужен прежний контекст, сделайте /compact перед перерывом, чтобы перезаписывать меньше.",
        metric: `${count}×`,
        potentialSavings: avoidable,
      });
    }
  }

  // Large context.
  {
    const large = events.filter((e) => contextTokens(e.event.tokens) > largeContextThreshold);
    const largeCost = large.reduce((s, e) => s + costTotal(e.cost), 0);
    const share = largeCost / total;
    if (large.length && share >= 0.2) {
      insights.push({
        id: "context.large", severity: share >= 0.5 ? "warning" : "info", kind: "freeWin",
        title: "Дорогой длинный контекст",
        detail: `${Fmt.percent(share)} стоимости (${Fmt.usd(largeCost)}) приходится на запросы с контекстом больше ${Fmt.tokens(largeContextThreshold)} токенов. Средний контекст запроса — ${Fmt.tokens(Math.trunc(summary.averageContextTokens))}.`,
        recommendation: "Каждый ход заново отправляет весь контекст сессии. Делайте /compact на длинных задачах, /clear между независимыми задачами, не читайте большие файлы и логи целиком и держите CLAUDE.md коротким.",
        metric: Fmt.percent(share),
      });
    }
  }

  // Model mix.
  {
    const topTier = events.filter((e) => isTopTier(modelFamily(e.event.model)));
    const topCost = topTier.reduce((s, e) => s + costTotal(e.cost), 0);
    const share = topCost / total;
    const whatIf = topTier.length ? costAsModel(pricing, topTier, cheaperModelPrefix) : undefined;
    if (topTier.length && share >= 0.7 && whatIf !== undefined && whatIf < topCost) {
      const cheaperName = pricing.models.find((m) => m.modelPrefix === cheaperModelPrefix)?.displayName ?? cheaperModelPrefix;
      insights.push({
        id: "model.mix", severity: "info", kind: "tradeoff",
        title: "Почти всё уходит на старшие модели",
        detail: `${Fmt.percent(share)} стоимости — Opus/Fable. Те же запросы на ${cheaperName} стоили бы ${Fmt.usd(whatIf)} вместо ${Fmt.usd(topCost)}.`,
        recommendation: `Для рутинных задач (правки, тесты, поиск по коду) переключайтесь на ${cheaperName} командой /model. На подписке это обычно медленнее расходует лимит окна. Качество на сложных задачах может отличаться — проверьте на своих.`,
        metric: Fmt.percent(share),
        potentialSavings: topCost - whatIf,
      });
    }
  }

  // Effort.
  {
    const high = events.filter((e) => ["xhigh", "max"].includes((e.event.effort ?? "").toLowerCase()));
    const thinkingShare = summary.tokens.output > 0 ? summary.tokens.thinking / summary.tokens.output : 0;
    const requestShare = high.length / summary.requests;
    if (requestShare >= 0.5 && thinkingShare >= 0.3) {
      insights.push({
        id: "effort.high", severity: "info", kind: "tradeoff",
        title: "Высокий effort по умолчанию",
        detail: `${Fmt.percent(requestShare)} запросов идут с effort xhigh/max; размышления — ${Fmt.percent(thinkingShare)} выходных токенов.`,
        recommendation: "Высокий effort окупается на сложных задачах. Для простых правок и вопросов понизьте effort в настройках модели Claude Code — это сокращает размышления и число вызовов инструментов.",
        metric: Fmt.percent(requestShare),
      });
    }
  }

  // Subagents.
  {
    const sidechain = events.filter((e) => e.event.isSidechain).reduce((s, e) => s + costTotal(e.cost), 0);
    const share = sidechain / total;
    if (share >= 0.3) {
      insights.push({
        id: "subagents", severity: "info", kind: "observation",
        title: "Субагенты — заметная часть расходов",
        detail: `${Fmt.percent(share)} стоимости (${Fmt.usd(sidechain)}) тратят субагенты. Каждый начинает со своего контекста и не делит кэш с основной сессией.`,
        recommendation: "Субагенты выгодны для объёмного чтения и поиска. Для мелких шагов, которым нужен контекст основной сессии, они обходятся дороже.",
        metric: Fmt.percent(share),
      });
    }
  }

  // One session dominates.
  {
    const sessions = sessionSummaries(events);
    const top = sessions[0];
    if (sessions.length >= 3 && top) {
      const share = top.summary.totalCost / total;
      if (share >= 0.3) {
        insights.push({
          id: "sessions.concentration", severity: "info", kind: "observation",
          title: "Одна сессия съела большую часть",
          detail: `Сессия в «${sessionProject(top)}» от ${Fmt.dateTime(top.start)} — ${Fmt.percent(share)} стоимости периода (${Fmt.usd(top.summary.totalCost)}, ${top.summary.requests} запросов, пик контекста ${Fmt.tokens(top.peakContextTokens)}).`,
          recommendation: "Длинные сессии дорожают с каждым ходом: весь накопленный контекст отправляется снова. Дробите большие задачи на сессии поменьше.",
          metric: Fmt.percent(share),
        });
      }
    }
  }

  // Fast mode.
  {
    const fast = events.filter((e) => isFastMode(e.event));
    if (fast.length && pricing.fastModeMultiplier > 1) {
      const fastCost = fast.reduce((s, e) => s + costTotal(e.cost), 0);
      const premium = fastCost * (1 - 1 / pricing.fastModeMultiplier);
      insights.push({
        id: "fast.mode", severity: "info", kind: "tradeoff",
        title: "Fast mode",
        detail: `${fast.length} запросов шли в fast mode: ${Fmt.usd(fastCost)}, из них наценка за скорость — ${Fmt.usd(premium)}.`,
        recommendation: "Включайте fast mode, когда важна скорость ответа, и выключайте для фоновых задач.",
        metric: `${fast.length}`,
        potentialSavings: premium,
      });
    }
  }

  // Request-level issues reported by the API.
  insights.push(...requestInsights(pricing, events, total));

  // Estimated prices.
  {
    const models = [...new Set(events.filter((e) => e.isEstimated).map((e) => e.event.model))].sort();
    if (models.length) {
      insights.push({
        id: "pricing.estimated", severity: "info", kind: "observation",
        title: "Цены для части моделей оценены",
        detail: `Для ${models.join(", ")} нет точной строки в таблице цен; стоимость взята по семейству модели.`,
        recommendation: "Добавьте эти модели в «Настройки → Цены».",
        metric: `${models.length}`,
      });
    }
  }

  return insights.sort((a, b) =>
    a.severity !== b.severity ? severityRank[b.severity] - severityRank[a.severity] : (b.potentialSavings ?? 0) - (a.potentialSavings ?? 0),
  );
}

/** Cache misses with a cause, reasoning the API dropped, refusals, cut-off answers, fallbacks. */
function requestInsights(pricing: PricingTable, events: PricedEvent[], total: number): Insight[] {
  const issues = requestIssues(pricing, events);
  const insights: Insight[] = [];

  if (issues.realMisses > 0) {
    const real = issues.misses.filter((g) => g.reason !== "previous_message_not_found" && g.reason !== "unavailable");
    const top = real[0];
    const parts = real.map((g) => `${cacheMissTitle(g.reason)} — ${Fmt.plural(g.count, "раз", "раза", "раз")}, ${Fmt.tokens(g.missedTokens)} токенов`);
    const share = total > 0 ? issues.realExtraCost / total : 0;
    insights.push({
      id: "cache.misses",
      severity: share >= 0.05 || issues.realMisses >= 10 ? "warning" : "info",
      kind: "freeWin",
      title: "Кэш сбрасывался из-за изменений в запросе",
      detail: `API сообщило о ${Fmt.plural(issues.realMisses, "промахе", "промахах", "промахах")} кэша с понятной причиной: ${parts.join("; ")}. Эти токены записаны в кэш заново вместо дешёвого чтения: ≈${Fmt.usd(issues.realExtraCost)}.`,
      recommendation: top ? cacheMissAdvice(top.reason) : undefined,
      metric: `${issues.realMisses}`,
      potentialSavings: issues.realExtraCost > 0 ? issues.realExtraCost : undefined,
    });
  }

  if (issues.droppedRequests > 0) {
    const reasons = issues.dropped.map((g) => `${droppedReasonTitle(g.reason)} — ${Fmt.plural(g.blocks, "блок", "блока", "блоков")}`);
    insights.push({
      id: "thinking.dropped",
      severity: issues.droppedRequests >= 10 ? "warning" : "info",
      kind: "freeWin",
      title: "Модель теряла свои прежние размышления",
      detail: `В ${Fmt.plural(issues.droppedRequests, "запросе", "запросах", "запросах")} API убрало из истории размышления модели: ${reasons.join("; ")}. Модель не видела, как рассуждала раньше, и восстанавливала это заново — лишний вывод и время.`,
      recommendation: "Не меняйте модель и историю посреди задачи: откат, правка сообщений, смена модели или настройки инструментов делают прежние размышления недействительными.",
      metric: `${issues.droppedRequests}`,
    });
  }

  if (issues.truncated > 0) {
    insights.push({
      id: "stop.max_tokens", severity: "warning", kind: "observation",
      title: "Ответы обрывались на лимите вывода",
      detail: `${Fmt.plural(issues.truncated, "ответ", "ответа", "ответов")} остановились по max_tokens: модель не успела закончить, и Claude Code продолжал или повторял запрос.`,
      recommendation: "Увеличьте лимит вывода (переменная CLAUDE_CODE_MAX_OUTPUT_TOKENS) или просите модель делать изменения меньшими частями.",
      metric: `${issues.truncated}`,
    });
  }

  if (issues.refusals.size > 0) {
    const count = [...issues.refusals.values()].reduce((a, b) => a + b, 0);
    const categories = [...issues.refusals.entries()].map(([c, n]) => `${c}: ${n}`).join(", ");
    insights.push({
      id: "stop.refusal", severity: "info", kind: "observation",
      title: "Модель отказывала в ответе",
      detail: `${Fmt.plural(count, "отказ", "отказа", "отказов")} по категориям защитных классификаторов (${categories}).${issues.fallbacks > 0 ? ` ${Fmt.plural(issues.fallbacks, "ответ", "ответа", "ответов")} дала резервная модель.` : ""}`,
      metric: `${count}`,
    });
  } else if (issues.fallbacks > 0) {
    insights.push({
      id: "stop.fallback", severity: "info", kind: "observation",
      title: "Отвечала резервная модель",
      detail: `${Fmt.plural(issues.fallbacks, "ответ", "ответа", "ответов")} дала резервная модель после отказа основной.`,
      metric: `${issues.fallbacks}`,
    });
  }

  if (issues.modelSwitches > 0) {
    insights.push({
      id: "model.switched", severity: "info", kind: "observation",
      title: "Запросы обслуживала другая модель",
      detail: `В ${Fmt.plural(issues.modelSwitches, "запросе", "запросах", "запросах")} ответила не та модель, которую запросил Claude Code (резервная модель или переключение). Кэш и размышления у разных моделей не общие.`,
      metric: `${issues.modelSwitches}`,
    });
  }

  return insights;
}
