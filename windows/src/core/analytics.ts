// Totals, grouping, time buckets, sessions and 5-hour windows.
// Port of XRayCore/Analytics/{Analytics,Sessions,UsageWindows}.swift. Times are epoch ms (local calendar).
import { addTokens, cacheHitRate, contextTokens, displayModelName, projectName, totalTokens, zeroTokens, type Tokens, type UsageEvent } from "./model";
import { addCost, costTotal, zeroCost, type Cost, type PricedEvent } from "./pricing";

/** Running totals over a set of priced events. */
export class UsageSummary {
  tokens: Tokens = zeroTokens();
  cost: Cost = zeroCost();
  requests = 0;
  webSearches = 0;
  webFetches = 0;
  estimatedRequests = 0;
  first?: number;
  last?: number;

  add(priced: PricedEvent): void {
    const e = priced.event;
    addTokens(this.tokens, e.tokens);
    addCost(this.cost, priced.cost);
    this.requests++;
    this.webSearches += e.webSearchRequests;
    this.webFetches += e.webFetchRequests;
    if (priced.isEstimated) this.estimatedRequests++;
    if (this.first === undefined || e.timestamp < this.first) this.first = e.timestamp;
    if (this.last === undefined || e.timestamp > this.last) this.last = e.timestamp;
  }

  static of(events: Iterable<PricedEvent>): UsageSummary {
    const summary = new UsageSummary();
    for (const e of events) summary.add(e);
    return summary;
  }

  get totalCost(): number {
    return costTotal(this.cost);
  }

  get totalTokens(): number {
    return totalTokens(this.tokens);
  }

  get cacheHitRate(): number {
    return cacheHitRate(this.tokens);
  }

  get averageContextTokens(): number {
    return this.requests > 0 ? contextTokens(this.tokens) / this.requests : 0;
  }

  get costPerRequest(): number {
    return this.requests > 0 ? this.totalCost / this.requests : 0;
  }
}

/** A named group (model, project, branch...) with its totals. */
export interface GroupSummary {
  key: string;
  summary: UsageSummary;
}

export const groupCost = (g: GroupSummary): number => g.summary.totalCost;

/** Totals for one calendar bucket, split by series. */
export interface TimeBucket {
  start: number;
  end: number;
  summary: UsageSummary;
  bySeries: Map<string, UsageSummary>;
}

/** One cell of the weekday x hour grid; weekday 0 = Monday ... 6 = Sunday. */
export interface HeatCell {
  weekday: number;
  hour: number;
  cost: number;
  requests: number;
}

export interface BurnRate {
  costPerHour: number;
  tokensPerMinute: number;
  requests: number;
  window: number;
}

export type CalendarUnit = "hour" | "day" | "week" | "month";

/** Start of the calendar unit containing `ms` (local time, weeks start on Monday). */
export function startOf(unit: CalendarUnit, ms: number): number {
  const d = new Date(ms);
  switch (unit) {
    case "hour":
      return new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours()).getTime();
    case "day":
      return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
    case "week": {
      const mondayOffset = (d.getDay() + 6) % 7;
      return new Date(d.getFullYear(), d.getMonth(), d.getDate() - mondayOffset).getTime();
    }
    case "month":
      return new Date(d.getFullYear(), d.getMonth(), 1).getTime();
  }
}

/** Start of the next unit after the one starting at `start`. */
export function nextStart(unit: CalendarUnit, start: number): number {
  const d = new Date(start);
  switch (unit) {
    case "hour":
      return new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours() + 1).getTime();
    case "day":
      return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime();
    case "week":
      return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 7).getTime();
    case "month":
      return new Date(d.getFullYear(), d.getMonth() + 1, 1).getTime();
  }
}

export interface Interval {
  start: number;
  end: number;
}

export const Analytics = {
  filter(events: PricedEvent[], interval?: Interval): PricedEvent[] {
    if (!interval) return events;
    return events.filter((e) => e.event.timestamp >= interval.start && e.event.timestamp <= interval.end);
  },

  /** Groups events by a key, sorted by cost (largest first). */
  group(events: PricedEvent[], key: (e: UsageEvent) => string): GroupSummary[] {
    const groups = new Map<string, UsageSummary>();
    for (const priced of events) {
      const k = key(priced.event);
      let summary = groups.get(k);
      if (!summary) groups.set(k, (summary = new UsageSummary()));
      summary.add(priced);
    }
    return [...groups.entries()]
      .map(([k, summary]) => ({ key: k, summary }))
      .sort((a, b) => (a.summary.totalCost === b.summary.totalCost ? (a.key < b.key ? -1 : 1) : b.summary.totalCost - a.summary.totalCost));
  },

  /** Buckets by calendar unit; every bucket between interval.start and interval.end is present. */
  buckets(events: PricedEvent[], unit: CalendarUnit, interval: Interval, series: (e: UsageEvent) => string): TimeBucket[] {
    const result: TimeBucket[] = [];
    const index = new Map<number, number>();
    let cursor = startOf(unit, interval.start);
    let guard = 0;
    while (cursor < interval.end && guard < 10_000) {
      const end = nextStart(unit, cursor);
      index.set(cursor, result.length);
      result.push({ start: cursor, end, summary: new UsageSummary(), bySeries: new Map() });
      cursor = end;
      guard++;
    }
    for (const priced of events) {
      const position = index.get(startOf(unit, priced.event.timestamp));
      if (position === undefined) continue;
      const bucket = result[position];
      bucket.summary.add(priced);
      const name = series(priced.event);
      let s = bucket.bySeries.get(name);
      if (!s) bucket.bySeries.set(name, (s = new UsageSummary()));
      s.add(priced);
    }
    return result;
  },

  /** Fixed-width buckets (e.g. 5 minutes) over an interval, for live charts. Width in ms. */
  fixedBuckets(events: PricedEvent[], interval: Interval, width: number): TimeBucket[] {
    const duration = interval.end - interval.start;
    if (width <= 0 || duration <= 0) return [];
    const count = Math.ceil(duration / width);
    const result: TimeBucket[] = Array.from({ length: count }, (_, i) => ({
      start: interval.start + i * width,
      end: interval.start + (i + 1) * width,
      summary: new UsageSummary(),
      bySeries: new Map(),
    }));
    for (const priced of events) {
      const offset = priced.event.timestamp - interval.start;
      if (offset < 0) continue;
      const i = Math.floor(offset / width);
      if (i < count) result[i].summary.add(priced);
    }
    return result;
  },

  /** Weekday x hour grid (Monday first), all 168 cells present. */
  heatmap(events: PricedEvent[]): HeatCell[] {
    const cells: HeatCell[] = [];
    for (let day = 0; day < 7; day++) for (let hour = 0; hour < 24; hour++) cells.push({ weekday: day, hour, cost: 0, requests: 0 });
    for (const priced of events) {
      const d = new Date(priced.event.timestamp);
      const mondayFirst = (d.getDay() + 6) % 7;
      const cell = cells[mondayFirst * 24 + d.getHours()];
      cell.cost += costTotal(priced.cost);
      cell.requests++;
    }
    return cells;
  },

  burnRate(events: PricedEvent[], now: number, window = 3_600_000): BurnRate {
    const from = now - window;
    const summary = UsageSummary.of(events.filter((e) => e.event.timestamp > from && e.event.timestamp <= now));
    return {
      costPerHour: summary.totalCost / (window / 3_600_000),
      tokensPerMinute: summary.totalTokens / (window / 60_000),
      requests: summary.requests,
      window,
    };
  },

  /** Share of requests per effort level (no effort counted as "default"). */
  effortDistribution(events: PricedEvent[]): GroupSummary[] {
    return Analytics.group(events, (e) => e.effort ?? "default");
  },
};

// MARK: Sessions

/** One Claude Code session (one transcript), with its totals. */
export interface SessionSummary {
  id: string;
  projectPath: string;
  gitBranch?: string;
  start: number;
  end: number;
  models: string[];
  summary: UsageSummary;
  /** API-equivalent cost of subagent (sidechain) requests. */
  sidechainCost: number;
  /** Largest prompt (fresh input + cache) seen in the session. */
  peakContextTokens: number;
}

export const sessionProject = (s: SessionSummary): string => projectName(s.projectPath);
export const sessionModelsLabel = (s: SessionSummary): string => s.models.map(displayModelName).join(", ");

/** One summary per session, most expensive first. */
export function sessionSummaries(events: PricedEvent[]): SessionSummary[] {
  const byID = new Map<string, SessionSummary>();
  const modelSets = new Map<string, Set<string>>();
  for (const priced of events) {
    const e = priced.event;
    const id = e.sessionID;
    let models = modelSets.get(id);
    if (!models) modelSets.set(id, (models = new Set()));
    models.add(e.model);
    const session = byID.get(id);
    if (session) {
      session.summary.add(priced);
      session.start = Math.min(session.start, e.timestamp);
      session.end = Math.max(session.end, e.timestamp);
      if (e.isSidechain) session.sidechainCost += costTotal(priced.cost);
      session.peakContextTokens = Math.max(session.peakContextTokens, contextTokens(e.tokens));
      session.gitBranch ??= e.gitBranch;
    } else {
      const summary = new UsageSummary();
      summary.add(priced);
      byID.set(id, {
        id,
        projectPath: e.projectPath,
        gitBranch: e.gitBranch,
        start: e.timestamp,
        end: e.timestamp,
        models: [],
        summary,
        sidechainCost: e.isSidechain ? costTotal(priced.cost) : 0,
        peakContextTokens: contextTokens(e.tokens),
      });
    }
  }
  return [...byID.values()]
    .map((s) => ({ ...s, models: [...(modelSets.get(s.id) ?? [])].sort() }))
    .sort((a, b) => (a.summary.totalCost === b.summary.totalCost ? b.start - a.start : b.summary.totalCost - a.summary.totalCost));
}

// MARK: 5-hour windows

/**
 * A Pro/Max usage window, reconstructed from activity: it starts at the hour of the first
 * request after the previous window ended and lasts five hours. An approximation.
 */
export interface UsageWindow {
  start: number;
  end: number;
  firstActivity: number;
  lastActivity: number;
  summary: UsageSummary;
  models: string[];
}

export const WINDOW_DURATION = 5 * 3_600_000;

export const Windows = {
  isActive: (w: UsageWindow, now: number): boolean => now >= w.start && now < w.end,
  remaining: (w: UsageWindow, now: number): number => Math.max(0, w.end - now),
  /** Elapsed fraction of the window, 0...1. */
  progress(w: UsageWindow, now: number): number {
    const duration = w.end - w.start;
    if (duration <= 0) return 1;
    return Math.min(1, Math.max(0, (now - w.start) / duration));
  },
  /** Cost at the end of the window if spending continues at the current pace. */
  projectedCost(w: UsageWindow, now: number): number {
    const cost = w.summary.totalCost;
    if (!Windows.isActive(w, now)) return cost;
    const active = Math.max(now - w.firstActivity, 5 * 60_000);
    return cost + (cost / active) * Windows.remaining(w, now);
  },

  /** Splits time-ordered events into consecutive windows. */
  compute(events: PricedEvent[], duration = WINDOW_DURATION): UsageWindow[] {
    const sorted = [...events].sort((a, b) => a.event.timestamp - b.event.timestamp);
    const windows: UsageWindow[] = [];
    let current: UsageWindow | undefined;
    let models = new Set<string>();
    const close = () => {
      if (current) {
        current.models = [...models].sort();
        windows.push(current);
      }
      current = undefined;
      models = new Set();
    };
    for (const priced of sorted) {
      const time = priced.event.timestamp;
      if (current && time >= current.end) close();
      if (!current) {
        const start = Windows.floorToHour(time);
        current = { start, end: start + duration, firstActivity: time, lastActivity: time, summary: new UsageSummary(), models: [] };
      }
      current.summary.add(priced);
      current.lastActivity = time;
      models.add(priced.event.model);
    }
    close();
    return windows;
  },

  /** Start of the UTC hour containing `ms`. */
  floorToHour: (ms: number): number => Math.floor(ms / 3_600_000) * 3_600_000,

  active(windows: UsageWindow[], now: number): UsageWindow | undefined {
    const last = windows[windows.length - 1];
    return last && Windows.isActive(last, now) ? last : undefined;
  },

  /** Largest completed window by API-equivalent cost. */
  peak(windows: UsageWindow[], now: number): UsageWindow | undefined {
    let best: UsageWindow | undefined;
    for (const w of windows) {
      if (Windows.isActive(w, now)) continue;
      if (!best || w.summary.totalCost > best.summary.totalCost) best = w;
    }
    return best;
  },
};
