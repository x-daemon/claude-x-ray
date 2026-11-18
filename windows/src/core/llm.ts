// Model requests ("LLM calls") of a session, their API-level details, and cache-miss analytics.
// Port of XRayCore/Activity/LLMCalls.swift.
import type { ActivityItem } from "./activity";
import { cacheWrite, contextTokens, normalizeModel, type RequestDetails } from "./model";
import { costTotal, matchPrice, type PricedEvent, type PricingTable } from "./pricing";
import type { ModelStep, SessionTrace, ToolExecution } from "./trace";

/** One request to the model: the response's blocks, the actions it took, usage and API details. */
export interface LLMCall {
  /** 1-based position in the session, in time order. */
  index: number;
  step: ModelStep;
  priced?: PricedEvent;
  /** Turn the request belongs to (0 is the session start, before the first prompt). */
  turn: number;
  thinking: ActivityItem[];
  replies: ActivityItem[];
  /** Tool calls the response made (its actions), with their results. */
  tools: ToolExecution[];
}

export const callDetails = (call: LLMCall): RequestDetails => call.priced?.event.details ?? {};

/** The model ran on a different model than Claude Code asked for. */
export function callModelSwitched(call: LLMCall): boolean {
  const requested = call.step.requestedModel ?? callDetails(call).requestedModel;
  const served = call.step.model ?? call.priced?.event.model;
  return !!requested && !!served && normalizeModel(requested) !== normalizeModel(served);
}

/** Thinking blocks the API dropped from the history before this request. */
export const droppedThinking = (d: RequestDetails): number =>
  (d.transformations ?? []).filter((t) => t.type === "thinking_dropped").length;

/** Something in the request needs attention: a cache miss with a known cause, lost reasoning, a refusal, a cut-off, a tool error. */
export function callHasIssue(call: LLMCall): boolean {
  const d = callDetails(call);
  return (
    (d.cacheMiss !== undefined && isRealMiss(d.cacheMiss.reason)) ||
    droppedThinking(d) > 0 ||
    d.stopReason === "refusal" ||
    d.stopReason === "max_tokens" ||
    callModelSwitched(call) ||
    call.tools.some((t) => t.result?.isError === true)
  );
}

export function buildLLMCalls(trace: SessionTrace, usage: Map<string, PricedEvent>): LLMCall[] {
  const toolByCall = new Map<string, ToolExecution>();
  for (const t of trace.tools) if (!toolByCall.has(t.call.id)) toolByCall.set(t.call.id, t);
  const turnOf = new Map<string, number>();
  for (const turn of trace.turns) for (const id of turn.stepIDs) if (!turnOf.has(id)) turnOf.set(id, turn.index);
  const itemsByMessage = new Map<string, ActivityItem[]>();
  for (const item of trace.items) {
    if (!item.messageID) continue;
    let list = itemsByMessage.get(item.messageID);
    if (!list) itemsByMessage.set(item.messageID, (list = []));
    list.push(item);
  }
  return trace.steps.map((step, i) => {
    const items = itemsByMessage.get(step.messageID) ?? [];
    return {
      index: i + 1,
      step,
      priced: usage.get(step.messageID),
      turn: turnOf.get(step.messageID) ?? 0,
      thinking: items.filter((x) => x.kind === "thinking"),
      replies: items.filter((x) => x.kind === "reply"),
      tools: step.toolCallIDs.map((id) => toolByCall.get(id)).filter((t): t is ToolExecution => !!t),
    };
  });
}

// MARK: Labels

export type Tone = "good" | "info" | "warning" | "critical" | "neutral";

/** Meaning of a stop reason and how alarming it is. */
export function stopReasonInfo(reason: string | undefined, category?: string): { title: string; tone: Tone } {
  switch (reason) {
    case "end_turn": return { title: "ответ готов", tone: "good" };
    case "tool_use": return { title: "вызов инструментов", tone: "info" };
    case "max_tokens": return { title: "обрезан лимитом вывода", tone: "warning" };
    case "stop_sequence": return { title: "стоп-последовательность", tone: "neutral" };
    case "pause_turn": return { title: "пауза серверного инструмента", tone: "neutral" };
    case "refusal": return { title: category ? `отказ: ${category}` : "отказ", tone: "critical" };
    case "model_context_window_exceeded": return { title: "окно контекста переполнено", tone: "critical" };
    case undefined: case "": return { title: "—", tone: "neutral" };
    default: return { title: reason, tone: "neutral" };
  }
}

/** Cache misses with a cause in the request itself, not just a missing comparison point. */
export const isRealMiss = (reason: string): boolean => reason !== "previous_message_not_found" && reason !== "unavailable";

export function cacheMissTitle(reason: string): string {
  switch (reason) {
    case "system_changed": return "изменился системный промпт";
    case "tools_changed": return "изменились инструменты (набор или описания)";
    case "messages_changed": return "изменилась история сообщений";
    case "model_changed": return "сменилась модель";
    case "multiple": return "изменилось несколько частей запроса";
    case "unrelated": return "запрос из другого разговора";
    case "previous_message_not_found": return "не с чем сравнить: первый запрос, пауза дольше TTL или другой поток";
    case "unavailable": return "диагностика недоступна";
    default: return reason;
  }
}

export function cacheMissAdvice(reason: string): string {
  switch (reason) {
    case "system_changed": return "Системный промпт менялся посреди сессии: правки CLAUDE.md или памяти, смена режима, настроек или версии Claude Code. Вносите такие изменения между сессиями.";
    case "tools_changed": return "Набор инструментов менялся по ходу: MCP-серверы подключались или отключались, менялись разрешения или описания инструментов. Подключайте нужные MCP до начала работы.";
    case "messages_changed": return "История сообщений менялась: откат (/rewind), правка или удаление сообщений, хуки, переписывающие ввод.";
    case "model_changed": return "Модель менялась посреди сессии (/model или резервная модель): у каждой модели свой кэш.";
    default: return "Держите системный промпт, инструменты и модель неизменными в течение сессии.";
  }
}

export function droppedReasonTitle(reason: string | undefined): string {
  switch (reason) {
    case "prefix_binding_mismatch": return "история изменилась после размышления";
    case "model_binding_mismatch": return "модель не читает размышления прежней модели";
    case "organization_binding_mismatch": return "размышление из другого аккаунта";
    case undefined: return "причина не указана";
    default: return reason;
  }
}

export function iterationTitle(type: string): string {
  switch (type) {
    case "message": return "ответ модели";
    case "fallback_message": return "ответ резервной модели";
    case "compaction": return "сжатие контекста на сервере";
    case "advisor_message": return "совет модели-советника";
    default: return type;
  }
}

export function thinkingDisplayTitle(display: string | undefined): string {
  switch (display) {
    case "summarized": return "краткое изложение";
    case "updates": return "заметки по ходу работы";
    case "omitted": return "текст не возвращается";
    case "redacted": return "зашифровано";
    default: return display ?? "—";
  }
}

export function decisionTitle(item: ActivityItem): string | undefined {
  if (!item.decision && !item.decidedBy) return item.permission;
  const verdict = item.decision === "accept" ? "разрешено" : item.decision === "reject" || item.decision === "deny" ? "запрещено" : item.decision ?? "решение";
  let by: string | undefined;
  switch (item.decidedBy) {
    case "classifier": by = "классификатор auto mode"; break;
    case "rule": by = "правило"; break;
    case "user": case "userApproval": by = "вы"; break;
    case "hook": by = "хук"; break;
    case "mode": by = "режим"; break;
    case "config": by = "настройки"; break;
    default: by = item.decidedBy;
  }
  const rule = item.ruleSource ? ` (${item.ruleSource})` : "";
  return by ? `${verdict}: ${by}${rule}` : verdict;
}

// MARK: Cache-miss analytics

export interface CacheMissGroup {
  reason: string;
  count: number;
  /** Prompt tokens the API reports as missed; for causes without a count, tokens written to the cache. */
  missedTokens: number;
  /** Extra cost of writing those tokens instead of reading them from the cache (API-equivalent USD). */
  extraCost: number;
  /** The API reported the missed tokens (as opposed to the written-tokens estimate). */
  exact: boolean;
}

export interface DroppedGroup {
  reason: string;
  requests: number;
  blocks: number;
}

export interface RequestIssues {
  requests: number;
  misses: CacheMissGroup[];
  /** Totals over misses with a cause in the request (not "nothing to compare with"). */
  realMisses: number;
  realMissedTokens: number;
  realExtraCost: number;
  dropped: DroppedGroup[];
  droppedRequests: number;
  refusals: Map<string, number>;
  truncated: number;
  fallbacks: number;
  modelSwitches: number;
  contextEdits: number;
  stopReasons: Map<string, number>;
}

/** Cost of writing `tokens` to the cache instead of reading them, at the request's model and TTL. */
export function missExtraCost(pricing: PricingTable, priced: PricedEvent, tokens: number): number {
  const price = matchPrice(pricing, priced.event.model).price;
  if (!price || tokens <= 0) return 0;
  const writeRate = priced.event.tokens.cacheWrite1h > 0 ? price.cacheWrite1h : price.cacheWrite5m;
  const multiplier = (priced.event.speed ?? "").toLowerCase() === "fast" ? pricing.fastModeMultiplier : 1;
  return Math.max(0, ((writeRate - price.cacheRead) * tokens * multiplier) / 1_000_000);
}

export function requestIssues(pricing: PricingTable, events: PricedEvent[]): RequestIssues {
  const misses = new Map<string, CacheMissGroup>();
  const dropped = new Map<string, DroppedGroup>();
  const refusals = new Map<string, number>();
  const stopReasons = new Map<string, number>();
  const issues: RequestIssues = {
    requests: events.length, misses: [], realMisses: 0, realMissedTokens: 0, realExtraCost: 0,
    dropped: [], droppedRequests: 0, refusals, truncated: 0, fallbacks: 0, modelSwitches: 0, contextEdits: 0, stopReasons,
  };
  for (const priced of events) {
    const d = priced.event.details;
    if (!d) continue;
    if (d.stopReason) stopReasons.set(d.stopReason, (stopReasons.get(d.stopReason) ?? 0) + 1);
    if (d.stopReason === "refusal") refusals.set(d.stopCategory ?? "—", (refusals.get(d.stopCategory ?? "—") ?? 0) + 1);
    if (d.stopReason === "max_tokens") issues.truncated++;
    if (d.iterations?.some((i) => i.type === "fallback_message")) issues.fallbacks++;
    if (d.requestedModel && normalizeModel(d.requestedModel) !== normalizeModel(priced.event.model)) issues.modelSwitches++;
    if (d.contextEdits?.length) issues.contextEdits++;
    if (d.cacheMiss) {
      const reason = d.cacheMiss.reason;
      const exact = d.cacheMiss.missedTokens !== undefined;
      const tokens = d.cacheMiss.missedTokens ?? cacheWrite(priced.event.tokens);
      const real = isRealMiss(reason);
      const extra = real ? missExtraCost(pricing, priced, tokens) : 0;
      let group = misses.get(reason);
      if (!group) misses.set(reason, (group = { reason, count: 0, missedTokens: 0, extraCost: 0, exact: true }));
      group.count++;
      group.missedTokens += tokens;
      group.extraCost += extra;
      group.exact &&= exact;
      if (real) {
        issues.realMisses++;
        issues.realMissedTokens += tokens;
        issues.realExtraCost += extra;
      }
    }
    const drops = (d.transformations ?? []).filter((t) => t.type === "thinking_dropped");
    if (drops.length) {
      issues.droppedRequests++;
      for (const t of drops) {
        const reason = t.reason ?? "unknown";
        let group = dropped.get(reason);
        if (!group) dropped.set(reason, (group = { reason, requests: 0, blocks: 0 }));
        group.blocks++;
      }
      for (const reason of new Set(drops.map((t) => t.reason ?? "unknown"))) dropped.get(reason)!.requests++;
    }
  }
  issues.misses = [...misses.values()].sort((a, b) => b.extraCost - a.extraCost || b.count - a.count);
  issues.dropped = [...dropped.values()].sort((a, b) => b.blocks - a.blocks);
  return issues;
}

/** Share of the context window the request filled. */
export const callContextTokens = (call: LLMCall): number => (call.priced ? contextTokens(call.priced.event.tokens) : 0);
export const callCost = (call: LLMCall): number => (call.priced ? costTotal(call.priced.cost) : 0);
