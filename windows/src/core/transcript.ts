// Transcript parsing and de-duplication. Port of XRayCore/Ingest/TranscriptParser.swift and UsageStore.swift.
import { dedupeKey, totalTokens, type ContextEdit, type InputTransformation, type RequestDetails, type RequestIteration, type Tokens, type UsageEvent } from "./model";

type Json = Record<string, unknown>;

const obj = (v: unknown): Json | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : undefined);
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
const int = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : undefined);
const bool = (v: unknown): boolean | undefined => (typeof v === "boolean" ? v : undefined);

export const json = { obj, str, int, bool };

/** ISO 8601 with or without fractional seconds; epoch milliseconds or undefined. */
export function parseDate(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : undefined;
}

/**
 * Parses one transcript line. Returns undefined for lines that carry no billed usage.
 * The format is internal to Claude Code, so every field is optional and a field of an
 * unexpected type is ignored instead of failing the line.
 */
export function parseUsageLine(line: string, fallbackSessionID = "unknown", fallbackProject = "unknown"): UsageEvent | undefined {
  // Cheap pre-filter: most lines never carry usage.
  if (!line.includes('"usage"') || !line.includes('"assistant"')) return undefined;
  let entry: Json | undefined;
  try {
    entry = obj(JSON.parse(line));
  } catch {
    return undefined;
  }
  if (!entry || entry.type !== "assistant") return undefined;
  const message = obj(entry.message);
  const usage = obj(message?.usage);
  if (!message || !usage) return undefined;

  const model = str(message.model) ?? "unknown";
  // Locally generated messages (errors, interruptions) use this placeholder; nothing was billed.
  if (model === "<synthetic>") return undefined;

  const creation = obj(usage.cache_creation);
  const write5m = int(creation?.ephemeral_5m_input_tokens);
  const write1h = int(creation?.ephemeral_1h_input_tokens);
  const totalWrite = int(usage.cache_creation_input_tokens) ?? 0;
  const splitKnown = (write5m ?? 0) + (write1h ?? 0);
  // Older transcripts only have the total; treat it as the default 5-minute TTL.
  const tokens: Tokens = {
    input: int(usage.input_tokens) ?? 0,
    output: int(usage.output_tokens) ?? 0,
    cacheRead: int(usage.cache_read_input_tokens) ?? 0,
    cacheWrite5m: splitKnown > 0 ? write5m ?? 0 : totalWrite,
    cacheWrite1h: splitKnown > 0 ? write1h ?? 0 : 0,
    thinking: int(obj(usage.output_tokens_details)?.thinking_tokens) ?? 0,
  };
  if (totalTokens(tokens) === 0) return undefined;

  const timestamp = parseDate(str(entry.timestamp));
  if (timestamp === undefined) return undefined;
  const messageID = str(message.id) ?? str(entry.uuid);
  if (!messageID) return undefined;

  const serverTools = obj(usage.server_tool_use);
  const gitBranch = str(entry.gitBranch);
  const details = requestDetails(entry, message, usage);
  return {
    messageID,
    requestID: str(entry.requestId),
    timestamp,
    model,
    sessionID: str(entry.sessionId) ?? fallbackSessionID,
    projectPath: str(entry.cwd) ?? fallbackProject,
    gitBranch: gitBranch ? gitBranch : undefined,
    isSidechain: bool(entry.isSidechain) ?? false,
    // The effort of this turn; `effort` alone is the session default.
    effort: str(entry.perTurnEffort) ?? str(entry.effort),
    speed: str(usage.speed),
    serviceTier: str(usage.service_tier),
    clientVersion: str(entry.version),
    tokens,
    webSearchRequests: int(serverTools?.web_search_requests) ?? 0,
    webFetchRequests: int(serverTools?.web_fetch_requests) ?? 0,
    details,
  };
}

const arr = (v: unknown): Json[] => (Array.isArray(v) ? (v.map(obj).filter(Boolean) as Json[]) : []);

/** Stop reason, cache diagnosis, input transformations, context edits and iterations of a request. */
function requestDetails(entry: Json, message: Json, usage: Json): RequestDetails | undefined {
  const details: RequestDetails = {};
  const stopReason = str(message.stop_reason);
  if (stopReason) details.stopReason = stopReason;
  const category = str(obj(message.stop_details)?.category);
  if (category) details.stopCategory = category;
  const requested = str(entry.requestedModel);
  if (requested) details.requestedModel = requested;
  const advisor = str(entry.advisorModel);
  if (advisor) details.advisorModel = advisor;
  const geo = str(usage.inference_geo);
  if (geo) details.inferenceGeo = geo;
  const ttl = str(entry.promptCacheRequested);
  if (ttl) details.cacheTTL = ttl;
  const miss = obj(obj(message.diagnostics)?.cache_miss_reason);
  const missType = str(miss?.type);
  if (missType) details.cacheMiss = { reason: missType, missedTokens: int(miss?.cache_missed_input_tokens) };
  const transformations: InputTransformation[] = arr(message.input_transformations)
    .map((t) => ({ type: str(t.type) ?? "unknown", reason: str(t.reason), path: str(t.path) }));
  if (transformations.length) details.transformations = transformations;
  const edits: ContextEdit[] = arr(obj(message.context_management)?.applied_edits)
    .map((e) => ({ type: str(e.type) ?? "unknown", clearedTokens: int(e.cleared_input_tokens), clearedToolUses: int(e.cleared_tool_uses) }));
  if (edits.length) details.contextEdits = edits;
  const iterations: RequestIteration[] = arr(usage.iterations).map((i) => {
    const creation = obj(i.cache_creation);
    const write = int(i.cache_creation_input_tokens) ?? (int(creation?.ephemeral_5m_input_tokens) ?? 0) + (int(creation?.ephemeral_1h_input_tokens) ?? 0);
    return {
      type: str(i.type) ?? "message",
      model: str(i.model),
      input: int(i.input_tokens) ?? 0,
      output: int(i.output_tokens) ?? 0,
      cacheRead: int(i.cache_read_input_tokens) ?? 0,
      cacheWrite: write,
    };
  });
  // A single plain "message" step is the request itself; keep only what adds information.
  if (iterations.length > 1 || iterations.some((i) => i.type !== "message")) details.iterations = iterations;
  return Object.keys(details).length ? details : undefined;
}

/**
 * De-duplicated, time-ordered set of usage events. The same response appears on several
 * lines (one per content block) and can be copied into a new session file on resume; when a
 * key repeats, the copy with the larger output count wins.
 */
export class UsageStore {
  events: UsageEvent[] = [];
  private indexByKey = new Map<string, number>();

  constructor(events: UsageEvent[] = []) {
    this.merge(events);
  }

  get count(): number {
    return this.events.length;
  }

  /** Merges new events. Returns how many were added or updated. */
  merge(newEvents: UsageEvent[]): number {
    let changed = 0;
    let needsSort = false;
    for (const event of newEvents) {
      const key = dedupeKey(event);
      const index = this.indexByKey.get(key);
      if (index !== undefined) {
        if (event.tokens.output > this.events[index].tokens.output) {
          this.events[index] = event;
          changed++;
        }
        continue;
      }
      const last = this.events[this.events.length - 1];
      if (last && event.timestamp < last.timestamp) needsSort = true;
      this.indexByKey.set(key, this.events.length);
      this.events.push(event);
      changed++;
    }
    if (needsSort) {
      this.events.sort((a, b) => (a.timestamp === b.timestamp ? (dedupeKey(a) < dedupeKey(b) ? -1 : 1) : a.timestamp - b.timestamp));
      this.indexByKey = new Map(this.events.map((e, i) => [dedupeKey(e), i]));
    }
    return changed;
  }

  removeAll(): void {
    this.events = [];
    this.indexByKey.clear();
  }
}
