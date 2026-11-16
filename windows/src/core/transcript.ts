// Transcript parsing and de-duplication. Port of XRayCore/Ingest/TranscriptParser.swift and UsageStore.swift.
import { dedupeKey, totalTokens, type Tokens, type UsageEvent } from "./model";

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
  return {
    messageID,
    requestID: str(entry.requestId),
    timestamp,
    model,
    sessionID: str(entry.sessionId) ?? fallbackSessionID,
    projectPath: str(entry.cwd) ?? fallbackProject,
    gitBranch: gitBranch ? gitBranch : undefined,
    isSidechain: bool(entry.isSidechain) ?? false,
    effort: str(entry.effort),
    speed: str(usage.speed),
    serviceTier: str(usage.service_tier),
    clientVersion: str(entry.version),
    tokens,
    webSearchRequests: int(serverTools?.web_search_requests) ?? 0,
    webFetchRequests: int(serverTools?.web_fetch_requests) ?? 0,
  };
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
