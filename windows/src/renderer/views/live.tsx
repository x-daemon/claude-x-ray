// "Сейчас": current 5-hour window, account limits, burn rate, live activity and the current session.
// Port of Views/LiveView.swift and Views/AccountLimitsView.swift.
import { useMemo, useState } from "preact/hooks";
import { Analytics, sessionProject, UsageSummary, Windows, type TimeBucket } from "../../core/analytics";
import { Fmt } from "../../core/fmt";
import { cacheHitRate, contextTokens, displayModelName } from "../../core/model";
import { planIsEmpty, windowFraction, windowHasReset, type PlanWindow, type SpendLimit } from "../../core/plan";
import { costTotal, type PricedEvent } from "../../core/pricing";
import { axis, axisTooltip, baseOption, BAR_MAX, EChart, tooltipHTML, usdAxisLabel, type ChartOption } from "../chart";
import * as I from "../icons";
import { store, useStore } from "../state";
import { C } from "../traceStyle";
import { Button, Card, Icon, Label, StatTile, Table, Tiles, UsageBar } from "../ui";
import { kindColor, kindIcon } from "../traceStyle";
import { ToolStatusChip, TraceStatusBanner } from "./traceParts";

export function LiveView() {
  const s = useStore();
  const now = s.now;
  const today = UsageSummary.of(s.todayEvents);
  const week = UsageSummary.of(s.lastSevenDaysEvents);
  const burn = Analytics.burnRate(s.priced.slice(-5000), now, 3_600_000);
  const session = s.currentSession;
  const from = now - 3 * 3_600_000;

  return (
    <div class="page">
      <LiveActivityCard />
      {s.isSubscription ? <AccountLimitsCard /> : null}
      <Card title="Окно 5 часов по логам этого компьютера" subtitle={s.isSubscription ? `подписка ${s.planTitle}` : undefined}>
        <WindowSummary />
      </Card>
      <Tiles>
        <StatTile title="Сегодня" value={Fmt.usd(today.totalCost)} caption={`${Fmt.tokens(today.totalTokens)} токенов · ${today.requests} запросов`} icon={I.Sun} />
        <StatTile title="7 дней" value={Fmt.usd(week.totalCost)} caption={`${Fmt.tokens(week.totalTokens)} токенов`} icon={I.Calendar} />
        <StatTile title="Темп за последний час" value={`${Fmt.usd(burn.costPerHour)}/ч`} caption={`${Fmt.tokens(Math.trunc(burn.tokensPerMinute))} токенов/мин`} icon={I.Flame} />
        <StatTile title="Кэш сегодня" value={today.requests > 0 ? Fmt.percent(today.cacheHitRate) : "—"} caption="доля контекста из кэша" icon={I.MemoryStick} />
      </Tiles>
      <Card title="Активность за 3 часа" subtitle={`${s.costLabel}, интервалы по 5 минут`}>
        <LiveActivityChart
          buckets={Analytics.fixedBuckets(s.events(from), { start: from, end: now }, 300_000)}
          windowStart={s.activeWindow?.start}
          now={now}
        />
      </Card>
      {session ? <CurrentSessionCard lastEvents={s.priced.slice(-12).reverse()} /> : null}
      {s.isSubscription ? (
        <p class="caption secondary">
          На подписке Pro/Max суммы — API-эквивалент по прайс-листу: деньги не списываются, но по ним видно, как быстро расходуется лимит. Границы окна восстанавливаются по активности; точный остаток лимита в логах не хранится.
        </p>
      ) : null}
    </div>
  );
}

/** Current window: spend, time left, pace and comparison with the personal peak. */
export function WindowSummary({ compact = false }: { compact?: boolean }) {
  const s = useStore();
  const now = s.now;
  const window = s.activeWindow;
  if (!window) {
    const last = s.priced[s.priced.length - 1];
    return (
      <div class="stack-6">
        <h3>Сейчас активного окна нет</h3>
        {last ? <div class="caption secondary">Последний запрос: {Fmt.dateTime(last.event.timestamp)}. Новое окно начнётся с первого запроса.</div> : null}
      </div>
    );
  }
  const cost = window.summary.totalCost;
  const peak = s.peakWindow;
  const ratio = peak && peak.summary.totalCost > 0 ? cost / peak.summary.totalCost : undefined;
  return (
    <div class="stack-10">
      <div class="row baseline gap-8">
        <span class={compact ? "hero-sm num" : "hero num"}>{Fmt.usd(cost)}</span>
        <span class="caption secondary">{s.costLabel}</span>
        <span class="spacer" />
        <div class="right-col">
          <div class="caption secondary">до сброса</div>
          <div class="title3 num">{Fmt.duration(Windows.remaining(window, now) / 1000)}</div>
        </div>
      </div>
      <div class="stack-5">
        <div class="caption secondary">Время окна: {Fmt.time(window.start, false)} – {Fmt.time(window.end, false)}</div>
        <UsageBar fraction={Windows.progress(window, now)} color={C.model} height={6} />
      </div>
      {peak && ratio !== undefined ? (
        <div class="stack-5">
          <div class="caption secondary">
            {Fmt.percent(ratio)} от вашего самого загруженного окна ({Fmt.usd(peak.summary.totalCost)}, {Fmt.dateTime(peak.start)})
          </div>
          <UsageBar fraction={ratio} color={ratio >= 0.9 ? C.critical : ratio >= 0.7 ? C.warning : C.model} height={6} />
        </div>
      ) : null}
      <div class="row gap-16 caption secondary nowrap-row">
        <Label icon={I.Hash} text={`${Fmt.tokens(window.summary.totalTokens)} токенов`} />
        <Label icon={I.ArrowUpDown} text={`${window.summary.requests} запросов`} />
        <Label icon={I.TrendingUp} text={`прогноз ${Fmt.usd(Windows.projectedCost(window, now))}`} />
        {!compact ? <Label icon={I.Cpu} text={window.models.map(displayModelName).join(", ")} /> : null}
      </div>
    </div>
  );
}

/** Per-5-minute spend for the last three hours, with a hover tooltip. */
function LiveActivityChart({ buckets, windowStart, now }: { buckets: TimeBucket[]; windowStart?: number; now: number }) {
  const p = store.palette;
  const active = buckets.filter((b) => b.summary.requests > 0);
  const option = useMemo<ChartOption>(() => {
    const labels = buckets.map((b) => Fmt.time(b.start, false));
    const windowIndex = windowStart !== undefined && buckets.length && windowStart > buckets[0].start
      ? buckets.findIndex((b) => b.start <= windowStart && windowStart < b.end)
      : -1;
    return {
      ...baseOption(p),
      grid: { left: 4, right: 12, top: 22, bottom: 4, containLabel: true },
      tooltip: axisTooltip(p, (i) => {
        const b = buckets[i];
        return tooltipHTML(`${Fmt.time(b.start, false)} – ${Fmt.time(b.end, false)}`, [
          { label: "Стоимость", value: Fmt.usd(b.summary.totalCost), color: p.roles.model },
          { label: "Токены", value: Fmt.tokens(b.summary.totalTokens) },
          { label: "Запросы", value: String(b.summary.requests) },
        ]);
      }),
      xAxis: {
        type: "category",
        data: labels,
        ...axis(p),
        splitLine: { show: true, interval: (i: number) => new Date(buckets[i]?.start ?? 0).getMinutes() % 30 === 0, lineStyle: { color: p.hairline } },
        axisLabel: { ...axis(p).axisLabel, interval: (i: number) => new Date(buckets[i]?.start ?? 0).getMinutes() % 30 === 0 },
      },
      yAxis: { type: "value", ...axis(p), min: 0, max: active.length ? undefined : 1, axisLabel: { ...axis(p).axisLabel, formatter: usdAxisLabel } },
      series: [{
        type: "bar",
        name: "Стоимость",
        barMaxWidth: BAR_MAX,
        barCategoryGap: "18%",
        itemStyle: { color: p.roles.model, borderRadius: [3, 3, 0, 0] },
        emphasis: { disabled: true },
        data: buckets.map((b) => (b.summary.requests > 0 ? b.summary.totalCost : null)),
        markLine: windowIndex >= 0 ? {
          silent: true,
          symbol: "none",
          lineStyle: { color: p.other, type: [4, 3], width: 1 },
          label: { show: true, position: "insideEndTop", formatter: "начало окна", color: p.text2, fontSize: 10 },
          data: [{ xAxis: windowIndex }],
        } : undefined,
      }],
    };
  }, [buckets, windowStart, p, now]);

  return (
    <div class="chart-wrap">
      <EChart option={option} height={200} label="Стоимость по 5-минутным интервалам за 3 часа" />
      {active.length === 0 ? <div class="chart-overlay"><span>За последние 3 часа запросов не было</span></div> : null}
    </div>
  );
}

/** The session of the latest request, plus the most recent requests. */
function CurrentSessionCard({ lastEvents }: { lastEvents: PricedEvent[] }) {
  const s = useStore();
  const session = s.currentSession!;
  const project = sessionProject(session);
  return (
    <Card title="Текущая сессия" subtitle={session.gitBranch ? `${project} · ${session.gitBranch}` : project}>
      <Tiles>
        <StatTile title="Стоимость" value={Fmt.usd(session.summary.totalCost)} />
        <StatTile title="Запросы" value={String(session.summary.requests)} />
        <StatTile title="Контекст сейчас" value={Fmt.tokens(lastEvents[0] ? contextTokens(lastEvents[0].event.tokens) : 0)} caption={`пик ${Fmt.tokens(session.peakContextTokens)}`} />
        <StatTile title="Кэш" value={Fmt.percent(session.summary.cacheHitRate)} />
      </Tiles>
      <Table
        class="compact"
        head={["Время", "Модель", "Контекст", "Вывод", "Кэш", "USD"]}
        numeric={[2, 3, 4, 5]}
        keys={lastEvents.map((p) => p.event.messageID + (p.event.requestID ?? ""))}
        rows={lastEvents.map((p) => {
          const e = p.event;
          return [
            <span class="num">{Fmt.time(e.timestamp)}</span>,
            displayModelName(e.model) + (e.isSidechain ? " · субагент" : ""),
            Fmt.tokens(contextTokens(e.tokens)),
            Fmt.tokens(e.tokens.output),
            Fmt.percent(cacheHitRate(e.tokens)),
            Fmt.usd(costTotal(p.cost)),
          ];
        })}
      />
    </Card>
  );
}

/** "What is Claude doing right now": live state plus the latest steps, linking to the full trace. */
function LiveActivityCard() {
  const s = useStore();
  const sessionID = s.traceSessions[0]?.id;
  if (!sessionID) return <NoRecentActivityBanner />;
  const trace = s.trace(sessionID);
  const usage = s.usageByMessage(sessionID);
  const items = trace.items.filter((i) => i.kind !== "context" && i.kind !== "toolResult").slice(-6).reverse();
  return (
    <div class="stack-10">
      <TraceStatusBanner trace={trace} usage={usage} />
      <div class="stack-4">
        {items.map((item) => {
          const tool = trace.tools.find((t) => t.call.id === item.id);
          const icon = kindIcon[item.kind];
          const color = item.isError ? C.critical : kindColor[item.kind];
          return (
            <div class="row gap-8 callout" key={item.id}>
              <span class="caption num secondary time-col">{Fmt.time(item.timestamp)}</span>
              <Icon icon={icon} size={15} color={color} />
              <span class="ellipsis">{item.title}</span>
              {tool ? <ToolStatusChip tool={tool} /> : null}
            </div>
          );
        })}
      </div>
      <div class="row gap-10">
        <Button icon={I.Waypoints} onClick={() => store.set("screen", "trace")}>Открыть Live-трассу</Button>
        <span class="caption secondary">промпты, размышления, инструменты, MCP, скиллы, контекст и поток — подробно и в реальном времени</span>
      </div>
    </div>
  );
}

/** Live screen when no local session wrote anything for 3 days. */
function NoRecentActivityBanner() {
  const s = useStore();
  const newest = s.newestTranscript;
  return (
    <div class="banner">
      <Icon icon={I.Moon} size={24} color={C.accent} />
      <div class="stack-4 callout grow">
        <h3>На этом компьютере Claude Code не работал последние 3 дня</h3>
        <div class="secondary">
          {newest ? `Последняя запись в логах: ${Fmt.dateTime(newest)}, ${Fmt.ago((s.now - newest) / 1000)}.` : "Логов Claude Code на этом компьютере пока нет."}
        </div>
        <div class="secondary">Облачные сессии (claude.ai/code, мобильное приложение Claude, облачная среда в Claude Desktop) X-Ray видит, только если включён приём на вкладке «Настройки → Облако»: их логи остаются на серверах Anthropic.</div>
      </div>
      <Button onClick={() => store.set("screen", "trace")}>Как увидеть сессию</Button>
    </div>
  );
}

// MARK: Account limits

/** The account's real plan limits, as Claude Code reports them to its status line. */
export function AccountLimitsCard() {
  const s = useStore();
  const now = s.now;
  const usage = s.planUsage;
  const subtitle = usage ? `из Claude Code · ${Fmt.ago((now - usage.capturedAt) / 1000)}` : "из Claude Code";
  return (
    <Card title="Лимиты аккаунта" subtitle={subtitle}>
      {usage && !planIsEmpty(usage) ? (
        <div class="stack-12">
          <div class="row top gap-28">
            {usage.fiveHour ? <LimitGauge title="5‑часовое окно" window={usage.fiveHour} now={now} /> : null}
            {usage.sevenDay ? <LimitGauge title="Неделя" window={usage.sevenDay} now={now} /> : null}
            {usage.spendLimit ? <SpendGauge spend={usage.spendLimit} /> : null}
          </div>
          <div class="caption secondary">
            Учитывает всё, что расходует подписку: чаты, облачные сессии, Cowork и сессии на этом компьютере. Claude Code обновляет эти цифры после каждого своего ответа в терминале на этом компьютере.
          </div>
          {now - usage.capturedAt > 3_600_000 ? (
            <Label icon={I.RotateCcwClock} class="caption warning-text" text={`Цифры на ${Fmt.dateTime(usage.capturedAt)}. Обновятся после следующего ответа Claude Code на этом компьютере.`} />
          ) : null}
        </div>
      ) : (
        <AccountLimitsSetup />
      )}
    </Card>
  );
}

export const limitColor = (fraction: number): string => (fraction >= 0.9 ? C.critical : fraction >= 0.7 ? C.warning : C.accent);

function LimitGauge({ title, window, now }: { title: string; window: PlanWindow; now: number }) {
  const fraction = windowFraction(window, now);
  const reset = windowHasReset(window, now)
    ? `окно сброшено ${Fmt.dateTime(window.resetsAt)}`
    : `сброс ${Fmt.dateTime(window.resetsAt)} · через ${Fmt.span((window.resetsAt - now) / 1000)}`;
  return (
    <div class="gauge">
      <div class="caption secondary">{title}</div>
      <div class="row baseline gap-6">
        <span class="gauge-value num">{Fmt.percent(fraction)}</span>
        <span class="caption secondary">использовано</span>
      </div>
      <UsageBar fraction={fraction} color={limitColor(fraction)} />
      <div class="caption secondary">{reset}</div>
    </div>
  );
}

function SpendGauge({ spend }: { spend: SpendLimit }) {
  const fraction = Math.min(Math.max(spend.usedPercentage / 100, 0), 1);
  return (
    <div class="gauge">
      <div class="caption secondary">Лимит расходов</div>
      <span class="gauge-value num">{Fmt.percent(fraction)}</span>
      <UsageBar fraction={fraction} color={limitColor(fraction)} />
      {spend.usedUSD !== undefined && spend.limitUSD !== undefined ? (
        <div class="caption secondary">{Fmt.usd(spend.usedUSD)} из {Fmt.usd(spend.limitUSD)}</div>
      ) : null}
    </div>
  );
}

/** Shown until Claude Code has reported plan usage: how to connect, or that it is connected. */
function AccountLimitsSetup() {
  const s = useStore();
  const [error, setError] = useState<string>();
  const state = s.statusLine;
  return (
    <div class="stack-8 callout">
      {state.type === "installed" ? (
        <Label icon={I.CircleCheck} class="secondary" text="Подключено. Цифры появятся после первого ответа Claude Code в терминале на этом компьютере: claude или claude --remote-control." />
      ) : state.type === "unreadable" ? (
        <div class="critical">Не удалось прочитать настройки Claude Code: {state.message}</div>
      ) : (
        <>
          <div class="secondary">
            Реальный процент 5‑часового и недельного лимита всего аккаунта, включая чаты, облачные сессии и Cowork. Claude Code сообщает его своей строке статуса; X-Ray подключается к ней и запоминает цифры.
          </div>
          <div class="row gap-8">
            <Button small onClick={async () => setError(await installStatusLine())}>Подключить</Button>
            <Button small onClick={() => openSettings("limits")}>Подробнее…</Button>
          </div>
        </>
      )}
      {error ? <div class="caption critical">{error}</div> : null}
    </div>
  );
}

export async function installStatusLine(): Promise<string | undefined> {
  const result = await store.bridge.installStatusLine();
  store.set("statusLine", result.state);
  return result.error;
}

export async function uninstallStatusLine(): Promise<string | undefined> {
  const result = await store.bridge.uninstallStatusLine();
  store.set("statusLine", result.state);
  return result.error;
}

export function openSettings(tab: string): void {
  store.settingsTab = tab;
  store.set("screen", "settings");
}

