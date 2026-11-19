// API list prices and costing. Port of XRayCore/Pricing/Pricing.swift.
import { familyReferencePrefix, isFastMode, modelFamily, normalizeModel, contextTokens, type UsageEvent } from "./model";
import { N } from "./i18n";

/** Per-model API list prices, USD per million tokens. */
export interface ModelPrice {
  /** Model id prefix this price applies to; the longest matching prefix wins. */
  modelPrefix: string;
  displayName: string;
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite5m: number;
  cacheWrite1h: number;
  /** Prompt size above which longContextMultiplier applies to every rate. */
  longContextThreshold?: number;
  longContextMultiplier?: number;
  /** Free-form note shown in the price editor. */
  note?: string;
}

/** Standard multipliers: 5-minute writes 1.25x input, 1-hour writes 2x input. */
export function modelPrice(p: Omit<ModelPrice, "cacheWrite5m" | "cacheWrite1h"> & Partial<Pick<ModelPrice, "cacheWrite5m" | "cacheWrite1h">>): ModelPrice {
  return { ...p, cacheWrite5m: p.cacheWrite5m ?? p.input * 1.25, cacheWrite1h: p.cacheWrite1h ?? p.input * 2 };
}

/** Dollar cost of one request (or a sum), split by what was billed. */
export interface Cost {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  webSearch: number;
}

export const zeroCost = (): Cost => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, webSearch: 0 });
export const costTotal = (c: Cost): number => c.input + c.output + c.cacheRead + c.cacheWrite + c.webSearch;

export function addCost(into: Cost, c: Cost): Cost {
  into.input += c.input;
  into.output += c.output;
  into.cacheRead += c.cacheRead;
  into.cacheWrite += c.cacheWrite;
  into.webSearch += c.webSearch;
  return into;
}

export interface PriceMatch {
  price?: ModelPrice;
  /** True when no exact prefix matched and the price was borrowed from the model family. */
  isEstimated: boolean;
}

/** A usage event together with its API-equivalent cost. */
export interface PricedEvent {
  event: UsageEvent;
  cost: Cost;
  /** Price came from a family fallback or is unknown (cost 0). */
  isEstimated: boolean;
}

/**
 * Editable price list. The defaults are public API list prices; for a Pro/Max subscription they
 * express the API-equivalent value of the usage, not money that is charged.
 */
export interface PricingTable {
  models: ModelPrice[];
  /** Fast mode (speed: "fast") multiplier applied to every rate. */
  fastModeMultiplier: number;
  /** USD per 1,000 server-side web searches. */
  webSearchPer1K: number;
  sourceNote: string;
}

export function matchPrice(table: PricingTable, model: string): PriceMatch {
  const id = normalizeModel(model);
  let best: ModelPrice | undefined;
  for (const price of table.models) {
    const prefix = price.modelPrefix.toLowerCase();
    if (!id.startsWith(prefix)) continue;
    const rest = id.slice(prefix.length);
    if (rest && !rest.startsWith("-")) continue;
    if (prefix.length > (best?.modelPrefix.length ?? -1)) best = price;
  }
  if (best) return { price: best, isEstimated: false };
  // Unknown version of a known family: borrow the family's current price.
  const fallbackPrefix = familyReferencePrefix[modelFamily(id)];
  const fallback = fallbackPrefix ? table.models.find((m) => m.modelPrefix === fallbackPrefix) : undefined;
  return fallback ? { price: fallback, isEstimated: true } : { isEstimated: true };
}

export function costOf(table: PricingTable, event: UsageEvent, price: ModelPrice | undefined): Cost {
  const webSearch = (event.webSearchRequests / 1000) * table.webSearchPer1K;
  if (!price) return { ...zeroCost(), webSearch };
  let multiplier = isFastMode(event) ? table.fastModeMultiplier : 1;
  if (price.longContextThreshold != null && price.longContextMultiplier != null && contextTokens(event.tokens) > price.longContextThreshold) {
    multiplier *= price.longContextMultiplier;
  }
  const perToken = multiplier / 1_000_000;
  const t = event.tokens;
  return {
    input: t.input * price.input * perToken,
    output: t.output * price.output * perToken,
    cacheRead: t.cacheRead * price.cacheRead * perToken,
    cacheWrite: (t.cacheWrite5m * price.cacheWrite5m + t.cacheWrite1h * price.cacheWrite1h) * perToken,
    webSearch,
  };
}

/** Prices a batch of events, matching each distinct model id once. */
export function priceEvents(table: PricingTable, events: UsageEvent[]): PricedEvent[] {
  const cache = new Map<string, PriceMatch>();
  return events.map((event) => {
    let match = cache.get(event.model);
    if (!match) {
      match = matchPrice(table, event.model);
      cache.set(event.model, match);
    }
    return { event, cost: costOf(table, event, match.price), isEstimated: match.isEstimated };
  });
}

/** Re-costs events as if they had run on another model (what-if estimates). */
export function costAsModel(table: PricingTable, events: PricedEvent[], modelPrefix: string): number | undefined {
  const target = table.models.find((m) => m.modelPrefix === modelPrefix);
  if (!target) return undefined;
  return events.reduce((sum, e) => sum + costTotal(costOf(table, e.event, target)), 0);
}

/** Adds default entries that a saved table does not have yet (new models after an update). */
export function mergingMissingDefaults(table: PricingTable, defaults: PricingTable = defaultPricing()): PricingTable {
  const known = new Set(table.models.map((m) => m.modelPrefix));
  return { ...table, models: [...table.models, ...defaults.models.filter((m) => !known.has(m.modelPrefix))] };
}

/**
 * Public API list prices, USD per million tokens (as of 2026-11-03). Cache writes follow the
 * standard 1.25x (5 min) / 2x (1 h) input multipliers. Verify against the pricing page.
 */
export function defaultPricing(): PricingTable {
  return {
    models: [
      modelPrice({ modelPrefix: "claude-fable-5-2", displayName: "Fable 5.2", input: 8, output: 40, cacheRead: 0.2 }),
      modelPrice({ modelPrefix: "claude-mythos-5-2", displayName: "Mythos 5.2", input: 8, output: 40, cacheRead: 0.2 }),
      modelPrice({ modelPrefix: "claude-fable-5-1", displayName: "Fable 5.1", input: 10, output: 50, cacheRead: 0.25 }),
      modelPrice({ modelPrefix: "claude-mythos-5-1", displayName: "Mythos 5.1", input: 10, output: 50, cacheRead: 0.25 }),
      modelPrice({ modelPrefix: "claude-fable-5", displayName: "Fable 5", input: 10, output: 50, cacheRead: 1.0 }),
      modelPrice({ modelPrefix: "claude-mythos-5", displayName: "Mythos 5", input: 10, output: 50, cacheRead: 1.0 }),
      modelPrice({ modelPrefix: "claude-opus-5-5", displayName: "Opus 5.5", input: 4, output: 20, cacheRead: 0.2 }),
      modelPrice({ modelPrefix: "claude-opus-5", displayName: "Opus 5", input: 5, output: 25, cacheRead: 0.5 }),
      modelPrice({ modelPrefix: "claude-opus-4-8", displayName: "Opus 4.8", input: 5, output: 25, cacheRead: 0.5 }),
      modelPrice({ modelPrefix: "claude-opus-4-7", displayName: "Opus 4.7", input: 5, output: 25, cacheRead: 0.5 }),
      modelPrice({ modelPrefix: "claude-opus-4-6", displayName: "Opus 4.6", input: 5, output: 25, cacheRead: 0.5 }),
      modelPrice({ modelPrefix: "claude-sonnet-5-5", displayName: "Sonnet 5.5", input: 2, output: 10, cacheRead: 0.1 }),
      modelPrice({ modelPrefix: "claude-sonnet-5", displayName: "Sonnet 5", input: 2, output: 10, cacheRead: 0.2 }),
      modelPrice({ modelPrefix: "claude-sonnet-4-6", displayName: "Sonnet 4.6", input: 3, output: 15, cacheRead: 0.3 }),
      modelPrice({
        modelPrefix: "claude-haiku-5-5", displayName: "Haiku 5.5", input: 0.1, output: 0.5, cacheRead: 0.01,
        longContextThreshold: 100_000, longContextMultiplier: 5,
        note: N("Свыше 100K токенов промпта — $0.50 / $2.50. Цена чтения кэша принята как 0.1× — проверьте."),
      }),
      modelPrice({ modelPrefix: "claude-haiku-4-5", displayName: "Haiku 4.5", input: 1, output: 5, cacheRead: 0.1 }),
    ],
    fastModeMultiplier: 2,
    webSearchPer1K: 10,
    sourceNote: N("Прайс-лист API на 2026-11-03"),
  };
}
