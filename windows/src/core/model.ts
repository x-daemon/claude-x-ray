// Core data model: token counters, usage events and the model catalog.
// Port of XRayCore/Model and Pricing/ModelCatalog.swift. Dates are epoch milliseconds.
import { labels, N } from "./i18n";

/** Token counters for one request (or a sum of requests), as in the transcript `usage` object. */
export interface Tokens {
  /** Fresh (uncached) input tokens. */
  input: number;
  /** Output tokens, thinking included. */
  output: number;
  /** Input tokens served from the prompt cache. */
  cacheRead: number;
  /** Input tokens written to the cache with the 5-minute TTL. */
  cacheWrite5m: number;
  /** Input tokens written to the cache with the 1-hour TTL. */
  cacheWrite1h: number;
  /** Thinking tokens (a subset of output). */
  thinking: number;
}

export const zeroTokens = (): Tokens => ({ input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, thinking: 0 });

export const cacheWrite = (t: Tokens): number => t.cacheWrite5m + t.cacheWrite1h;
/** Everything the model read for the request: fresh input + cache reads + cache writes. */
export const contextTokens = (t: Tokens): number => t.input + t.cacheRead + cacheWrite(t);
/** Every token billed for the request. */
export const totalTokens = (t: Tokens): number => contextTokens(t) + t.output;
/** Share of the prompt served from the cache, 0...1. */
export const cacheHitRate = (t: Tokens): number => {
  const context = contextTokens(t);
  return context > 0 ? t.cacheRead / context : 0;
};

export function addTokens(into: Tokens, t: Tokens): Tokens {
  into.input += t.input;
  into.output += t.output;
  into.cacheRead += t.cacheRead;
  into.cacheWrite5m += t.cacheWrite5m;
  into.cacheWrite1h += t.cacheWrite1h;
  into.thinking += t.thinking;
  return into;
}

/** A step the API ran inside one request (main answer, fallback model, server-side compaction). */
export interface RequestIteration {
  type: string;
  model?: string;
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
}

/** A change the API made to the request before the model saw it (e.g. a thinking block dropped). */
export interface InputTransformation {
  type: string;
  reason?: string;
  path?: string;
}

/** Context the server cleared before the request (context editing). */
export interface ContextEdit {
  type: string;
  clearedTokens?: number;
  clearedToolUses?: number;
}

/**
 * API-level details of one model request, as Claude Code records them: why the response ended,
 * the cache diagnosis, what the API changed in the input, and the steps it ran.
 */
export interface RequestDetails {
  /** end_turn, tool_use, max_tokens, stop_sequence, pause_turn, refusal. */
  stopReason?: string;
  /** stop_details.category of a refusal (cyber, bio...). */
  stopCategory?: string;
  /** Model Claude Code asked for, when the transcript has it. */
  requestedModel?: string;
  /** Advisor tool model configured for the request. */
  advisorModel?: string;
  /** Where inference ran (usage.inference_geo). */
  inferenceGeo?: string;
  /** Cache TTL Claude Code requested ("5m" or "1h"). */
  cacheTTL?: string;
  /** Why the prompt cache missed, from the API's cache diagnostics. */
  cacheMiss?: { reason: string; missedTokens?: number };
  /** Changes the API made to the input, e.g. thinking blocks it dropped. */
  transformations?: InputTransformation[];
  /** Context the server cleared (context editing). */
  contextEdits?: ContextEdit[];
  /** Steps of the request when there was more than the main answer. */
  iterations?: RequestIteration[];
}

/** One billed model request recorded by Claude Code. */
export interface UsageEvent {
  /** Anthropic message id (msg_...). */
  messageID: string;
  /** API request id (req_...), when the transcript has it. */
  requestID?: string;
  /** Epoch milliseconds. */
  timestamp: number;
  /** Model id as reported by the API, e.g. claude-opus-5-5. */
  model: string;
  sessionID: string;
  /** Working directory of the Claude Code session. */
  projectPath: string;
  gitBranch?: string;
  /** True for subagent (sidechain) requests. */
  isSidechain: boolean;
  effort?: string;
  /** standard or fast. */
  speed?: string;
  serviceTier?: string;
  clientVersion?: string;
  tokens: Tokens;
  webSearchRequests: number;
  webFetchRequests: number;
  /** API-level details (stop reason, cache diagnosis...). */
  details?: RequestDetails;
}

/**
 * Claude Code writes one transcript line per content block of a response, each carrying the same
 * usage; events are de-duplicated on this key so the bill is not doubled or tripled.
 */
export const dedupeKey = (e: UsageEvent): string => (e.requestID ? `${e.messageID}|${e.requestID}` : e.messageID);

/** Last path component of the project directory (handles / and \ separators). */
export function projectName(projectPath: string): string {
  const trimmed = projectPath.replace(/[\\/]+$/, "");
  const parts = trimmed.split(/[\\/]/).filter(Boolean);
  const name = parts.length ? parts[parts.length - 1] : trimmed;
  return name || projectPath;
}

export const isFastMode = (e: UsageEvent): boolean => (e.speed ?? "").toLowerCase() === "fast";

// MARK: Model catalog

export type ModelFamily = "opus" | "sonnet" | "haiku" | "fable" | "mythos" | "other";

export const familyTitle: Record<ModelFamily, string> = labels({
  opus: "Opus",
  sonnet: "Sonnet",
  haiku: "Haiku",
  fable: "Fable",
  mythos: "Mythos",
  other: N("Другие"),
});

/** Price entry used when a model id of this family has no exact entry. */
export const familyReferencePrefix: Record<ModelFamily, string | undefined> = {
  opus: "claude-opus-5-5",
  sonnet: "claude-sonnet-5-5",
  haiku: "claude-haiku-5-5",
  fable: "claude-fable-5-2",
  mythos: "claude-mythos-5-2",
  other: undefined,
};

/** Top-tier families, the first candidates for a what-if on a cheaper model. */
export const isTopTier = (f: ModelFamily): boolean => f === "opus" || f === "fable" || f === "mythos";

export function modelFamily(model: string): ModelFamily {
  const id = model.toLowerCase();
  for (const family of ["mythos", "fable", "opus", "sonnet", "haiku"] as const) {
    if (id.includes(family)) return family;
  }
  return "other";
}

/**
 * Normalises provider-specific ids: us.anthropic.claude-opus-4-8-v1:0, claude-opus-4-5@20251101,
 * claude-opus-5-5[1m] -> plain claude-... ids.
 */
export function normalizeModel(model: string): string {
  let id = model.toLowerCase().trim();
  const start = id.indexOf("claude-");
  if (start >= 0) id = id.slice(start);
  for (const separator of ["@", "[", ":"]) {
    const index = id.indexOf(separator);
    if (index >= 0) id = id.slice(0, index);
  }
  if (id.endsWith("-v1") || id.endsWith("-v2")) id = id.slice(0, -3);
  return id;
}

/** Context window in tokens. Current models have 1M; Haiku 4.5 and older models 200K. */
export function contextWindow(model: string): number {
  if (model.toLowerCase().includes("[1m]")) return 1_000_000;
  const id = normalizeModel(model);
  const oneMillion = [
    "claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7",
    "claude-opus-4-6", "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-5-5",
  ];
  return oneMillion.some((prefix) => id.startsWith(prefix)) ? 1_000_000 : 200_000;
}

const capitalize = (s: string): string => (s ? s[0].toUpperCase() + s.slice(1).toLowerCase() : s);
const isNumber = (s: string): boolean => /^\d+$/.test(s);

/** Human-readable name: claude-opus-5-5 -> Opus 5.5, claude-sonnet-4-5-20250929 -> Sonnet 4.5. */
export function displayModelName(model: string): string {
  const id = normalizeModel(model);
  if (!id.startsWith("claude-")) return model;
  const parts = id.slice("claude-".length).split("-").filter(Boolean);
  const name = parts[0];
  if (!name) return model;
  // Old ids put the version first: claude-3-5-sonnet.
  if (isNumber(name)) {
    const words = parts.filter((p) => !isNumber(p) && p.length > 2);
    const numbers = parts.filter((p) => p.length <= 2 && isNumber(p));
    const title = capitalize(words[0] ?? name);
    return numbers.length ? `${title} ${numbers.join(".")}` : title;
  }
  // Version parts are short numbers; a date suffix (8 digits) ends the version.
  const version: string[] = [];
  for (const part of parts.slice(1)) {
    if (part.length > 2 || !isNumber(part)) break;
    version.push(part);
  }
  const title = capitalize(name);
  return version.length ? `${title} ${version.join(".")}` : title;
}
