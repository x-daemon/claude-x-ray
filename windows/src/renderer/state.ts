// Renderer state: the events and activity from the main process, settings, and everything the
// screens derive from them. Port of the macOS app's AppModel.
import { useEffect, useState } from "preact/hooks";
import type { ActivityItem } from "../core/activity";
import { Analytics, sessionSummaries, startOf, Windows, type CalendarUnit, type Interval, type SessionSummary, type UsageWindow } from "../core/analytics";
import { Fmt } from "../core/fmt";
import { buildLLMCalls, type LLMCall } from "../core/llm";
import { displayModelName, type UsageEvent } from "../core/model";
import type { PlanUsage } from "../core/plan";
import { priceEvents, type PricedEvent, type PricingTable } from "../core/pricing";
import { ActivityStore, buildTrace, stateIsActive, stateTitle, type LiveStatus, type SessionActivity, type SessionTrace } from "../core/trace";
import { UsageStore } from "../core/transcript";
import type { Delta, InitialState, ReceiverStatus, ScanInfo, Settings, StatusLineState, XRayBridge } from "../shared/api";
import { applyPalette, palette, type Palette } from "./theme";
import { L, language, N, setLanguage, titled, type Language } from "../core/i18n";

export type Screen = "live" | "trace" | "overview" | "sessions" | "projects" | "models" | "insights" | "reports" | "settings";
export type Period = "today" | "week" | "month" | "quarter" | "all";
export type TraceTab = "feed" | "flow" | "llm" | "timeline" | "context" | "tools";

export const SCREENS: { id: Screen; title: string }[] = titled([
  { id: "live", title: N("Сейчас") },
  { id: "trace", title: N("Live-трасса") },
  { id: "overview", title: N("Обзор") },
  { id: "sessions", title: N("Сессии") },
  { id: "projects", title: N("Проекты") },
  { id: "models", title: N("Модели") },
  { id: "insights", title: N("Оптимизация") },
  { id: "reports", title: N("Отчёты") },
]);

export const PERIODS: { id: Period; title: string }[] = titled([
  { id: "today", title: N("Сегодня") },
  { id: "week", title: N("7 дней") },
  { id: "month", title: N("30 дней") },
  { id: "quarter", title: N("90 дней") },
  { id: "all", title: N("Всё время") },
]);

export const TRACE_TABS: { id: TraceTab; title: string }[] = titled([
  { id: "feed", title: N("Лента") },
  { id: "flow", title: N("Поток") },
  { id: "llm", title: N("LLM-запросы") },
  { id: "timeline", title: N("Таймлайн") },
  { id: "context", title: N("Контекст") },
  { id: "tools", title: N("Инструменты · MCP · скиллы") },
]);

export const PLANS: { id: Settings["plan"]; title: string }[] = titled([
  { id: "pro", title: "Pro" },
  { id: "max5x", title: "Max 5×" },
  { id: "max20x", title: "Max 20×" },
  { id: "api", title: N("API (оплата за токены)") },
]);

/** The series for models past the colored slots. */
export const otherSeries = (): string => L`Другие`;
const MAX_COLORED_MODELS = 7;
const DAY = 86_400_000;

export class Store {
  bridge!: XRayBridge;
  ready = false;
  settings!: Settings;
  directories: string[] = [];
  pricing!: PricingTable;
  planUsage?: PlanUsage;
  statusLine: StatusLineState = { type: "notInstalled" };
  statusLinePath = "";
  receiver!: ReceiverStatus;
  receiverToken = "";
  viewerToken = "";
  computerName = "";
  detectedAddress?: string;
  scan!: ScanInfo;
  platform = "win32";
  version = "";
  supportDir = "";
  homeDir = "";
  isPopup = false;
  /** The report is being rendered for a PDF: light palette, no hover hints. */
  exporting = false;

  private usage = new UsageStore();
  activity = new ActivityStore();
  priced: PricedEvent[] = [];
  windows: UsageWindow[] = [];
  modelOrder: string[] = [];
  now = Date.now();
  palette: Palette = palette("s2a", false);

  // UI state
  screen: Screen = "live";
  period: Period = "month";
  traceTab: TraceTab = "feed";
  pinnedTrace?: string;
  selectedSession?: string;
  settingsTab = "appearance";

  private listeners = new Set<() => void>();
  private traceCache = new Map<string, { key: string; trace: SessionTrace }>();
  private memos = new Map<string, { key: string; value: unknown }>();
  private activityVersion = 0;
  private pricedVersion = 0;

  /** Caches a derived value until its key changes. */
  private memo<T>(name: string, key: string, compute: () => T): T {
    const hit = this.memos.get(name);
    if (hit && hit.key === key) return hit.value as T;
    const value = compute();
    this.memos.set(name, { key, value });
    return value;
  }

  private get dayKey(): string {
    return String(startOf("day", this.now));
  }
  private darkQuery = typeof window !== "undefined" ? window.matchMedia("(prefers-color-scheme: dark)") : undefined;

  subscribe(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  emit(): void {
    for (const fn of this.listeners) fn();
  }

  /** Switches the interface language; cached results hold texts, so they are computed again. */
  applyLanguage(lang: Language): void {
    if (typeof document !== "undefined") document.documentElement.lang = lang;
    if (lang === language()) return;
    setLanguage(lang);
    this.memos.clear();
  }

  set<K extends keyof this>(key: K, value: this[K]): void {
    this[key] = value;
    this.emit();
  }

  // MARK: Loading

  async start(bridge: XRayBridge): Promise<void> {
    this.bridge = bridge;
    const state = await bridge.init();
    this.apply(state);
    bridge.onDelta((delta) => this.applyDelta(delta));
    bridge.onPlanUsage((usage) => {
      this.planUsage = usage;
      this.emit();
    });
    bridge.onReceiver((status) => {
      this.receiver = status;
      this.emit();
    });
    bridge.onSettings((settings, directories, lang) => {
      this.settings = settings;
      this.directories = directories;
      this.applyLanguage(lang);
      this.applyTheme();
      this.emit();
    });
    this.darkQuery?.addEventListener("change", () => {
      this.applyTheme();
      this.emit();
    });
    setInterval(() => {
      this.now = Date.now();
      this.emit();
    }, 15_000);
  }

  apply(state: InitialState): void {
    this.applyLanguage(state.language);
    this.settings = state.settings;
    this.directories = state.directories;
    this.pricing = state.pricing;
    this.planUsage = state.planUsage;
    this.statusLine = state.statusLine;
    this.statusLinePath = state.statusLineSettingsPath;
    this.receiver = state.receiver;
    this.receiverToken = state.receiverToken;
    this.viewerToken = state.viewerToken;
    this.computerName = state.computerName;
    this.detectedAddress = state.detectedAddress;
    this.scan = state.scan;
    this.platform = state.platform;
    this.version = state.version;
    this.supportDir = state.supportDir;
    this.homeDir = state.homeDir;
    this.isPopup = state.isPopup;
    this.usage = new UsageStore(state.events);
    this.activity = new ActivityStore();
    this.activity.merge(state.activities);
    this.activityVersion++;
    this.recompute();
    this.applyTheme();
    this.ready = true;
    this.emit();
  }

  applyDelta(delta: Delta): void {
    if (delta.reset) {
      this.usage = new UsageStore();
      this.activity = new ActivityStore();
    }
    const changed = this.usage.merge(delta.events);
    if (delta.activities.length) {
      this.activity.merge(delta.activities);
      this.activityVersion++;
    }
    this.scan = delta.scan;
    this.now = Date.now();
    if (changed > 0 || delta.reset) this.recompute();
    this.emit();
  }

  recompute(): void {
    this.pricedVersion++;
    this.priced = priceEvents(this.pricing, this.usage.events);
    this.windows = Windows.compute(this.priced);
    this.modelOrder = Analytics.group(this.priced, (e) => displayModelName(e.model)).map((g) => g.key);
  }

  get isDark(): boolean {
    const a = this.settings?.appearance ?? "auto";
    return a === "dark" || (a === "auto" && !!this.darkQuery?.matches);
  }

  applyTheme(): void {
    if (this.exporting) return;
    this.palette = applyPalette(this.settings?.theme ?? "s2a", this.isDark);
  }

  async updateSettings(patch: Partial<Settings>): Promise<void> {
    this.settings = await this.bridge.updateSettings(patch);
    this.applyTheme();
    this.emit();
  }

  async setPricing(table: PricingTable | null): Promise<void> {
    this.pricing = await this.bridge.setPricing(table);
    this.recompute();
    this.emit();
  }

  // MARK: Derived data

  get hasData(): boolean {
    return this.priced.length > 0;
  }

  get isSubscription(): boolean {
    return this.settings.plan !== "api";
  }

  get costLabel(): string {
    return this.isSubscription ? L`API-эквивалент` : L`Стоимость`;
  }

  get planTitle(): string {
    return PLANS.find((p) => p.id === this.settings.plan)?.title ?? "";
  }

  periodInterval(period: Period = this.period): Interval | undefined {
    const today = startOf("day", this.now);
    const tomorrow = addDays(today, 1);
    const daysBack = (n: number): Interval => ({ start: addDays(today, -n), end: tomorrow });
    switch (period) {
      case "today": return { start: today, end: tomorrow };
      case "week": return daysBack(6);
      case "month": return daysBack(29);
      case "quarter": return daysBack(89);
      case "all": {
        const first = this.priced[0]?.event.timestamp;
        return first === undefined ? undefined : { start: Math.min(startOf("day", first), today), end: tomorrow };
      }
    }
  }

  get periodEvents(): PricedEvent[] {
    return this.memo("periodEvents", `${this.pricedVersion}|${this.period}|${this.dayKey}`, () => Analytics.filter(this.priced, this.periodInterval()));
  }

  /** The same length of time right before the selected period; undefined for "all time". */
  get previousPeriodEvents(): PricedEvent[] | undefined {
    return this.memo("previousPeriodEvents", `${this.pricedVersion}|${this.period}|${this.dayKey}`, () => {
      const previous = this.previousPeriodInterval;
      if (!previous) return undefined;
      const first = this.priced[0]?.event.timestamp;
      if (first === undefined || first >= previous.end) return undefined;
      return Analytics.filter(this.priced, { start: previous.start, end: previous.end - 1 });
    });
  }

  /** The same length of time right before the selected period; undefined for "all time". */
  get previousPeriodInterval(): Interval | undefined {
    const interval = this.periodInterval();
    if (this.period === "all" || !interval) return undefined;
    return { start: interval.start - (interval.end - interval.start), end: interval.start };
  }

  get periodChartUnit(): CalendarUnit {
    const interval = this.periodInterval();
    if (!interval) return "day";
    const duration = interval.end - interval.start;
    if (duration <= 2 * DAY) return "hour";
    if (duration > 120 * DAY) return "week";
    return "day";
  }

  events(since: number): PricedEvent[] {
    return this.priced.filter((e) => e.event.timestamp >= since);
  }

  get todayEvents(): PricedEvent[] {
    return this.memo("today", `${this.pricedVersion}|${this.dayKey}`, () => this.events(startOf("day", this.now)));
  }

  get lastSevenDaysEvents(): PricedEvent[] {
    return this.memo("week", `${this.pricedVersion}|${Math.floor(this.now / 60_000)}`, () => this.events(this.now - 7 * DAY));
  }

  /** The session of the latest request. */
  get currentSession(): SessionSummary | undefined {
    const last = this.priced[this.priced.length - 1];
    if (!last) return undefined;
    const id = last.event.sessionID;
    return sessionSummaries(this.lastSevenDaysEvents.filter((e) => e.event.sessionID === id))[0];
  }

  get activeWindow(): UsageWindow | undefined {
    return Windows.active(this.windows, this.now);
  }

  get peakWindow(): UsageWindow | undefined {
    return Windows.peak(this.windows, this.now);
  }

  get newestTranscript(): number | undefined {
    const dates = (this.scan?.sources ?? []).map((s) => s.newestModification).filter((d): d is number => d !== undefined);
    return dates.length ? Math.max(...dates) : undefined;
  }

  /** Sessions with recent activity for the live trace, most recently active first. */
  get traceSessions(): SessionActivity[] {
    return this.memo("traceSessions", String(this.activityVersion), () => this.activity.sessions());
  }

  get traceSessionID(): string | undefined {
    if (this.pinnedTrace && this.activity.items.some((i) => i.sessionID === this.pinnedTrace)) return this.pinnedTrace;
    return this.traceSessions[0]?.id;
  }

  trace(sessionID: string): SessionTrace {
    // Cached per activity version and minute; the live banner ticks on its own.
    const key = `${this.activityVersion}|${Math.floor(this.now / 15_000)}`;
    const cached = this.traceCache.get(sessionID);
    if (cached && cached.key === key) return cached.trace;
    const trace = buildTrace(sessionID, this.activity.itemsForSession(sessionID), Date.now());
    this.traceCache.set(sessionID, { key, trace });
    return trace;
  }

  get liveStatus(): LiveStatus | undefined {
    const id = this.traceSessions[0]?.id;
    return id ? this.trace(id).status : undefined;
  }

  /** Priced usage of a session keyed by message id (joins trace steps with tokens and cost). */
  usageByMessage(sessionID: string): Map<string, PricedEvent> {
    return this.memo(`usage|${sessionID}`, String(this.pricedVersion), () => {
      const result = new Map<string, PricedEvent>();
      for (const p of this.priced) if (p.event.sessionID === sessionID) result.set(p.event.messageID, p);
      return result;
    });
  }

  /** Model requests of a session with their actions, usage and API details. */
  llmCalls(sessionID: string): LLMCall[] {
    return this.memo(`llm|${sessionID}`, `${this.activityVersion}|${this.pricedVersion}|${Math.floor(this.now / 15_000)}`, () =>
      buildLLMCalls(this.trace(sessionID), this.usageByMessage(sessionID)),
    );
  }

  /** Tray tooltip: the account's 5-hour usage and the current window's cost, labelled. */
  get trayTooltip(): string {
    const parts: string[] = [];
    const window = this.planUsage?.fiveHour;
    if (window && this.planUsage && this.now - this.planUsage.capturedAt < 3 * 3_600_000 && this.now < window.resetsAt) {
      parts.push(L`лимит 5 ч ${Fmt.percent(Math.min(Math.max(window.usedPercentage / 100, 0), 1))}`);
    }
    const active = this.activeWindow;
    if (active) parts.push(L`окно ${Fmt.usd(active.summary.totalCost)}`);
    const live = this.liveStatus;
    if (live && stateIsActive(live.state)) parts.push(stateTitle(live.state));
    return ["S2A Claude X-Ray", ...parts].join(" · ");
  }

  /** Short title like the macOS menu bar: real 5-hour usage and the window's cost. */
  get trayTitle(): string {
    const parts: string[] = [];
    const window = this.planUsage?.fiveHour;
    if (window && this.planUsage && this.now - this.planUsage.capturedAt < 3 * 3_600_000 && this.now < window.resetsAt) {
      parts.push(Fmt.percent(Math.min(Math.max(window.usedPercentage / 100, 0), 1)));
    }
    const active = this.activeWindow;
    if (active) parts.push(Fmt.usd(active.summary.totalCost));
    if (!parts.length) return this.hasData ? "—" : "X-Ray";
    return parts.join(" · ");
  }

  /** Series name for an event: the model's display name, or "Другие" past the colored slots. */
  seriesName(event: UsageEvent): string {
    const name = displayModelName(event.model);
    const index = this.modelOrder.indexOf(name);
    return index >= 0 && index < MAX_COLORED_MODELS ? name : otherSeries();
  }

  /** Domain and colors for the series in a chart; each model keeps its color everywhere. */
  colorScale(names: Iterable<string>): { domain: string[]; range: string[] } {
    const present = new Set(names);
    const domain: string[] = [];
    const range: string[] = [];
    this.modelOrder.slice(0, MAX_COLORED_MODELS).forEach((name, i) => {
      if (present.has(name)) {
        domain.push(name);
        range.push(this.palette.series[i % this.palette.series.length]);
      }
    });
    if (present.has(otherSeries())) {
      domain.push(otherSeries());
      range.push(this.palette.other);
    }
    return { domain, range };
  }

  modelColor(name: string): string {
    const index = this.modelOrder.indexOf(name);
    return index >= 0 && index < MAX_COLORED_MODELS ? this.palette.series[index % this.palette.series.length] : this.palette.other;
  }

  items(sessionID: string): ActivityItem[] {
    return this.activity.itemsForSession(sessionID);
  }
}

/** Same local time n calendar days later (handles daylight saving changes). */
export function addDays(ms: number, days: number): number {
  const d = new Date(ms);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + days, d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds()).getTime();
}

export const store = new Store();

/** Re-renders the component whenever the store changes. */
export function useStore(): Store {
  const [, setTick] = useState(0);
  useEffect(() => store.subscribe(() => setTick((t) => t + 1)), []);
  return store;
}

/** Current time, re-rendering the component every `interval` ms (live banners and timers). */
export function useNow(interval = 1000): number {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), interval);
    return () => clearInterval(timer);
  }, [interval]);
  return now;
}
