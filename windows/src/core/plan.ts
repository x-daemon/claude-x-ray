// Account plan usage from Claude Code's status line, and upload validation for the cloud receiver.
// Port of XRayCore/Plan/PlanUsage.swift and Receiver/TranscriptUpload.swift.
import { displayModelName } from "./model";
import { parseDate } from "./transcript";

/** A rolling limit window (5 hours or 7 days). */
export interface PlanWindow {
  /** Share of the limit used, 0–100. */
  usedPercentage: number;
  /** Epoch ms. */
  resetsAt: number;
}

export interface SpendLimit {
  usedPercentage: number;
  resetsAt?: number;
  usedUSD?: number;
  limitUSD?: number;
  period?: string;
}

/**
 * How much of the claude.ai plan limits the whole account has used, as Claude Code reports it to
 * its status line (rate_limits). It counts chats, cloud sessions, Cowork and local sessions alike.
 */
export interface PlanUsage {
  /** Epoch ms when the status line received these numbers. */
  capturedAt: number;
  fiveHour?: PlanWindow;
  sevenDay?: PlanWindow;
  spendLimit?: SpendLimit;
  model?: string;
  version?: string;
}

export const windowHasReset = (w: PlanWindow, now: number): boolean => now >= w.resetsAt;
/** Used share 0...1 at now; zero once the window has reset. */
export const windowFraction = (w: PlanWindow, now: number): number =>
  windowHasReset(w, now) ? 0 : Math.min(Math.max(w.usedPercentage / 100, 0), 1);

export const planIsEmpty = (u: PlanUsage): boolean => !u.fiveHour && !u.sevenDay && !u.spendLimit;

/** Fills windows missing from this report with the previous report's, unless they have reset since. */
export function mergePlanUsage(current: PlanUsage, previous?: PlanUsage): PlanUsage {
  if (!previous) return current;
  const result = { ...current };
  if (!result.fiveHour && previous.fiveHour && !windowHasReset(previous.fiveHour, current.capturedAt)) result.fiveHour = previous.fiveHour;
  if (!result.sevenDay && previous.sevenDay && !windowHasReset(previous.sevenDay, current.capturedAt)) result.sevenDay = previous.sevenDay;
  if (!result.spendLimit && previous.spendLimit && (previous.spendLimit.resetsAt === undefined || current.capturedAt < previous.spendLimit.resetsAt)) {
    result.spendLimit = previous.spendLimit;
  }
  return result;
}

type Json = Record<string, unknown>;
const obj = (v: unknown): Json | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : undefined);

function number(raw: unknown): number | undefined {
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  if (typeof raw === "string" && raw.trim() !== "" && Number.isFinite(Number(raw))) return Number(raw);
  return undefined;
}

/** Unix seconds (milliseconds when the number is that large) or an ISO 8601 string; epoch ms. */
function date(raw: unknown): number | undefined {
  const n = number(raw);
  if (n !== undefined) return n > 100_000_000_000 ? n : n * 1000;
  return typeof raw === "string" ? parseDate(raw) : undefined;
}

function modelName(root: Json): string | undefined {
  const model = obj(root.model);
  if (model) {
    if (typeof model.display_name === "string") return model.display_name;
    if (typeof model.id === "string") return displayModelName(model.id);
    return undefined;
  }
  return typeof root.model === "string" ? displayModelName(root.model) : undefined;
}

function planWindow(raw: unknown): PlanWindow | undefined {
  const fields = obj(raw);
  const used = number(fields?.used_percentage);
  const resets = date(fields?.resets_at);
  return used !== undefined && resets !== undefined ? { usedPercentage: used, resetsAt: resets } : undefined;
}

function parseRoot(text: string): Json | undefined {
  try {
    return obj(JSON.parse(text));
  } catch {
    return undefined;
  }
}

/** Plan usage from the status line JSON; undefined without rate_limits. */
export function planUsageFromStatusLine(text: string, capturedAt = Date.now()): PlanUsage | undefined {
  const root = parseRoot(text);
  const limits = obj(root?.rate_limits);
  if (!root || !limits) return undefined;
  const usage: PlanUsage = { capturedAt, fiveHour: planWindow(limits.five_hour), sevenDay: planWindow(limits.seven_day) };
  const spend = obj(limits.spend_limit);
  const spendUsed = number(spend?.used_percentage);
  if (spend && spendUsed !== undefined) {
    usage.spendLimit = {
      usedPercentage: spendUsed,
      resetsAt: date(spend.resets_at),
      usedUSD: number(spend.used_usd),
      limitUSD: number(spend.limit_usd),
      period: typeof spend.period === "string" ? spend.period : undefined,
    };
  }
  usage.model = modelName(root);
  usage.version = typeof root.version === "string" ? root.version : undefined;
  return planIsEmpty(usage) ? undefined : usage;
}

/** Status line text: Opus 5.5 · контекст 42% · 5 ч 38% · неделя 22%. */
export function statusLineSummary(text: string, usage: PlanUsage | undefined, now = Date.now()): string {
  const root = parseRoot(text) ?? {};
  const parts: string[] = [];
  const model = modelName(root);
  if (model) parts.push(model);
  const context = number(obj(root.context_window)?.used_percentage);
  if (context !== undefined) parts.push(`контекст ${Math.round(context)}%`);
  if (usage?.fiveHour && !windowHasReset(usage.fiveHour, now)) parts.push(`5 ч ${Math.round(usage.fiveHour.usedPercentage)}%`);
  if (usage?.sevenDay && !windowHasReset(usage.sevenDay, now)) parts.push(`неделя ${Math.round(usage.sevenDay.usedPercentage)}%`);
  return parts.length ? parts.join(" · ") : "S2A X-Ray";
}

// MARK: Uploads from cloud sessions

/** The lines that are JSON objects, each ending with a newline; anything else is dropped. */
export function validUploadLines(body: string): { data: string; accepted: number; rejected: number } {
  let data = "";
  let accepted = 0;
  let rejected = 0;
  for (const raw of body.split("\n")) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (!line) continue;
    try {
      const parsed = JSON.parse(line);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        data += line + "\n";
        accepted++;
        continue;
      }
    } catch {
      // not JSON
    }
    rejected++;
  }
  return { data, accepted, rejected };
}

/** Letters, digits, ., _ and -; not . or ..; at most 200 characters. */
export function isSafeComponent(component: string): boolean {
  return component.length > 0 && component.length <= 200 && component !== "." && component !== ".." && /^[A-Za-z0-9._-]+$/.test(component);
}

/** Where an upload is stored, relative to the cloud folder; undefined when unsafe. */
export function uploadRelativePath(path: string | undefined, session: string | undefined, project: string | undefined): string | undefined {
  if (path) {
    const parts = path.split("/").filter(Boolean);
    if (parts.length < 1 || parts.length > 6 || !parts.every(isSafeComponent) || !parts[parts.length - 1].endsWith(".jsonl")) return undefined;
    return parts.join("/");
  }
  if (!session || !isSafeComponent(session)) return undefined;
  const folder = project && isSafeComponent(project) ? project : "cloud";
  return `${folder}/${session}.jsonl`;
}

/** Compares secrets without stopping at the first difference. */
export function constantTimeEquals(a: string, b: string): boolean {
  const x = Buffer.from(a, "utf8");
  const y = Buffer.from(b, "utf8");
  let difference = x.length === y.length ? 0 : 1;
  for (let i = 0; i < Math.max(x.length, y.length); i++) difference |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return difference === 0;
}
