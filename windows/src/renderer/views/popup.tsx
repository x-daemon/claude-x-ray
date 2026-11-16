// Tray popup: the live window at a glance. Port of Views/MenuBarView.swift.
import { Analytics, UsageSummary } from "../../core/analytics";
import { Fmt } from "../../core/fmt";
import { windowFraction, windowHasReset, type PlanWindow } from "../../core/plan";
import { stateDetail, stateIsActive, stateTitle, type LiveStatus } from "../../core/trace";
import { BrandMark } from "../brand";
import * as I from "../icons";
import { useNow, useStore } from "../state";
import { stateColor, stateIcon } from "../traceStyle";
import { Button, Icon } from "../ui";
import { limitColor, WindowSummary } from "./live";

export function Popup() {
  const s = useStore();
  const today = UsageSummary.of(s.todayEvents);
  const burn = Analytics.burnRate(s.priced.slice(-2000), s.now, 3_600_000);
  const status = s.liveStatus;
  const usage = s.planUsage;
  return (
    <div class="popup">
      <div class="row gap-8">
        <BrandMark size={22} />
        <span class="headline">S2A Claude X-Ray</span>
        <span class="spacer" />
        {s.scan?.scanning ? <span class="spinner" aria-label="Чтение логов" /> : null}
      </div>
      {status ? <StatusLine status={status} /> : null}
      <WindowSummary compact />
      <hr />
      <div class="popup-grid callout">
        {usage?.fiveHour ? <PlanRow title="Лимит 5 ч" window={usage.fiveHour} now={s.now} /> : null}
        {usage?.sevenDay ? <PlanRow title="Неделя" window={usage.sevenDay} now={s.now} /> : null}
        <span class="secondary">Сегодня</span>
        <span class="num">{Fmt.usd(today.totalCost)}</span>
        <span class="secondary">{Fmt.tokens(today.totalTokens)} ток.</span>
        <span class="secondary">Темп за час</span>
        <span class="num">{Fmt.usd(burn.costPerHour)}/ч</span>
        <span class="secondary">{burn.requests} запр.</span>
        <span class="secondary">Кэш сегодня</span>
        <span class="num">{today.requests > 0 ? Fmt.percent(today.cacheHitRate) : "—"}</span>
        <span />
      </div>
      <hr />
      <div class="row gap-8">
        <Button primary onClick={() => void s.bridge.openMain()}>Открыть X-Ray</Button>
        <Button title="Обновить" onClick={() => void s.bridge.rescan()} icon={I.RotateCw}>{""}</Button>
        <Button title="Настройки" onClick={() => void s.bridge.openMain("settings")} icon={I.Settings}>{""}</Button>
        <span class="spacer" />
        <Button onClick={() => void s.bridge.quit()}>Выйти</Button>
      </div>
    </div>
  );
}

function PlanRow({ title, window, now }: { title: string; window: PlanWindow; now: number }) {
  const fraction = windowFraction(window, now);
  return (
    <>
      <span class="secondary">{title}</span>
      <span class="num" style={fraction >= 0.7 ? { color: limitColor(fraction) } : undefined}>{Fmt.percent(fraction)}</span>
      <span class="secondary">{windowHasReset(window, now) ? "сброшен" : `сброс через ${Fmt.span((window.resetsAt - now) / 1000)}`}</span>
    </>
  );
}

/** One-line live state, ticking every second. */
function StatusLine({ status }: { status: LiveStatus }) {
  const now = useNow(1000);
  const color = stateColor[status.state.type];
  const detail = stateDetail(status.state);
  return (
    <div class="popup-status" style={{ "--state": color } as Record<string, string>}>
      <Icon icon={stateIcon[status.state.type]} size={16} color={color} class={stateIsActive(status.state) ? "pulse" : undefined} />
      <div class="stack-2 min0">
        <div class="callout strong">{stateTitle(status.state)} · {Fmt.shortDuration(Math.max(0, now - status.since) / 1000)}</div>
        {detail ? <div class="mono caption clamp2">{detail}</div> : null}
        <div class="caption secondary">ответов модели {status.stepsInTurn} · инструментов {status.toolsInTurn}</div>
      </div>
    </div>
  );
}
