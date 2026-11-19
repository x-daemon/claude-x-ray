// Renderer entry: the main window (sidebar, top bar, screens) or the tray popup.
// Port of Views/RootView.swift and the window chrome of S2AClaudeXRayApp.swift.
import { render } from "preact";
import { useEffect, useState } from "preact/hooks";
import { Fmt } from "../core/fmt";
import type { XRayBridge } from "../shared/api";
import { BrandHeader } from "./brand";
import * as I from "./icons";
import { mockBridge } from "./mockBridge";
import { PERIODS, SCREENS, store, TRACE_TABS, useStore, type Period, type Screen, type TraceTab } from "./state";
import { C } from "./traceStyle";
import { Icon, Segmented } from "./ui";
import { BreakdownView } from "./views/breakdown";
import { InsightsView } from "./views/insights";
import { LiveView } from "./views/live";
import { OverviewView } from "./views/overview";
import { Popup } from "./views/popup";
import { finishExport, prepareExport, ReportsView } from "./views/reports";
import { SessionsView } from "./views/sessions";
import { SettingsView } from "./views/settings";
import { SourcesHelp } from "./views/sources";
import { TraceView } from "./views/trace";
import { L } from "../core/i18n";

const SCREEN_ICONS: Record<Screen, typeof I.Activity> = {
  live: I.Activity,
  trace: I.Waypoints,
  overview: I.ChartColumn,
  sessions: I.Rows3,
  projects: I.Folder,
  models: I.Cpu,
  insights: I.Lightbulb,
  reports: I.FileText,
  settings: I.Settings,
};

function screenTitle(screen: Screen): string {
  return screen === "settings" ? L`Настройки` : SCREENS.find((s) => s.id === screen)?.title ?? "S2A Claude X-Ray";
}

function App() {
  const s = useStore();
  if (!s.ready) return <div class="boot"><span class="spinner" /></div>;
  if (s.isPopup) return <Popup />;
  return <MainWindow />;
}

function MainWindow() {
  const s = useStore();
  const [dragging, setDragging] = useState(false);
  const showsPeriod = s.screen !== "live" && s.screen !== "trace" && s.screen !== "settings";
  const fixedLayout = s.screen === "trace" || s.screen === "sessions" || s.screen === "reports" || s.screen === "settings";
  const empty = !s.hasData && s.scan?.lastScan !== undefined && s.screen !== "settings";

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // Same shortcuts as the macOS menu: refresh, rescan everything, import a session log.
      if (e.ctrlKey && e.shiftKey && e.key.toLowerCase() === "r") {
        e.preventDefault();
        void s.bridge.fullRescan();
      } else if ((e.ctrlKey && e.key.toLowerCase() === "r") || e.key === "F5") {
        e.preventDefault();
        void s.bridge.rescan();
      }
      if (e.ctrlKey && e.key.toLowerCase() === "i") {
        e.preventDefault();
        void s.bridge.importDialog();
      }
      if (e.ctrlKey && e.key === ",") {
        e.preventDefault();
        store.set("screen", "settings");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // The tray tooltip follows the same numbers as the macOS menu bar title.
  const tooltip = s.trayTooltip;
  useEffect(() => s.bridge.setTrayTitle(tooltip), [tooltip]);

  // Session logs dropped on the window, for example from a cloud session.
  const onDrop = (e: DragEvent) => {
    e.preventDefault();
    setDragging(false);
    const files = [...(e.dataTransfer?.files ?? [])];
    const paths = files.map((f) => s.bridge.pathForFile(f)).filter((p) => /\.(jsonl|zip)$/i.test(p));
    if (paths.length) void s.bridge.importPaths(paths);
  };

  return (
    <div
      class="app"
      onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
      onDragLeave={(e) => { if (e.relatedTarget === null) setDragging(false); }}
      onDrop={onDrop}
    >
      <aside class="sidebar">
        <div class="drag"><BrandHeader /></div>
        <nav class="nav">
          {SCREENS.map((item) => (
            <button key={item.id} type="button" class={item.id === s.screen ? "nav-item on" : "nav-item"} onClick={() => store.set("screen", item.id)}>
              <Icon icon={SCREEN_ICONS[item.id]} size={17} />
              <span>{item.title}</span>
            </button>
          ))}
          <div class="nav-sep" />
          <button type="button" class={s.screen === "settings" ? "nav-item on" : "nav-item"} onClick={() => store.set("screen", "settings")}>
            <Icon icon={I.Settings} size={17} />
            <span>{L`Настройки`}</span>
          </button>
        </nav>
        <ScanStatus />
      </aside>
      <main class="main">
        <header class="topbar drag">
          <h1>{screenTitle(s.screen)}</h1>
          {showsPeriod ? (
            <div class="no-drag period-picker">
              <Segmented value={s.period} options={PERIODS} onChange={(period) => store.set("period", period)} label={L`Период`} />
            </div>
          ) : null}
          <span class="spacer" />
          <button class="btn borderless no-drag" type="button" title={L`Перечитать новые записи (Ctrl+R)`} disabled={s.scan?.scanning} onClick={() => void s.bridge.rescan()}>
            <Icon icon={I.RotateCw} size={16} class={s.scan?.scanning ? "spin" : undefined} />
            <span>{L`Обновить`}</span>
          </button>
        </header>
        <div class={fixedLayout && !empty ? "content fixed" : "content"} data-scroll>
          {empty ? <SourcesHelp title={L`Логи Claude Code не найдены`} icon={I.Inbox} /> : <Screen screen={s.screen} />}
        </div>
      </main>
      {dragging ? (
        <div class="drop-overlay">
          <Icon icon={I.Download} size={40} />
          <div class="title3">{L`Отпустите, чтобы импортировать логи сессий (.jsonl, .zip)`}</div>
        </div>
      ) : null}
    </div>
  );
}

function Screen({ screen }: { screen: Screen }) {
  switch (screen) {
    case "live": return <LiveView />;
    case "trace": return <TraceView />;
    case "overview": return <OverviewView />;
    case "sessions": return <SessionsView />;
    case "projects": return <BreakdownView key="project" dimension="project" />;
    case "models": return <BreakdownView key="model" dimension="model" />;
    case "insights": return <InsightsView />;
    case "reports": return <ReportsView />;
    case "settings": return <SettingsView />;
  }
}

/** Footer of the sidebar: when the data was last read and when Claude Code last wrote a log. */
function ScanStatus() {
  const s = useStore();
  const scan = s.scan;
  const newest = s.newestTranscript;
  const help = L`${Fmt.plural(scan?.filesSeen ?? 0, "лог", "лога", "логов")}, ${Fmt.plural(s.priced.length, "ответ", "ответа", "ответов")} модели. Новые строки логов подхватываются автоматически. Облачные сессии попадают сюда, если включён приём («Настройки → Облако») или их лог импортирован.`;
  return (
    <div class="scan-status caption secondary" title={help}>
      <div class="row gap-6">
        {scan?.scanning ? (<><span class="spinner small" /><span>{L`Чтение логов…`}</span></>)
          : scan?.lastScan ? (<><Icon icon={I.Radio} size={14} color={C.good} /><span>{L`Обновлено ${Fmt.time(scan.lastScan)}`}</span></>)
            : <span>{L`Ожидание…`}</span>}
      </div>
      {scan?.lastScan ? <div class="indent">{newest ? L`Последний лог: ${Fmt.ago((s.now - newest) / 1000)}` : L`Логов на этом компьютере нет`}</div> : null}
    </div>
  );
}

// MARK: Boot

/** Navigation requests from the main process (tray menu, snapshot runs) and from the dev harness. */
function navigate(target: { screen?: string; tab?: string; period?: string; scroll?: string }): void {
  if (target.screen && (target.screen === "settings" || SCREENS.some((s) => s.id === target.screen))) store.screen = target.screen as Screen;
  if (target.tab) {
    if (store.screen === "settings") store.settingsTab = target.tab;
    else if (TRACE_TABS.some((t) => t.id === target.tab)) store.traceTab = target.tab as TraceTab;
  }
  if (target.period && PERIODS.some((p) => p.id === target.period)) store.period = target.period as Period;
  store.emit();
  if (target.scroll) {
    requestAnimationFrame(() => {
      for (const el of document.querySelectorAll<HTMLElement>("[data-scroll]")) el.scrollTop = target.scroll === "bottom" ? el.scrollHeight : 0;
    });
  }
}

declare global {
  interface Window {
    xray?: XRayBridge;
    __xrayPrepareExport?: () => Promise<{ width: number; height: number }>;
    __xrayFinishExport?: () => void;
    __xrayNavigate?: typeof navigate;
  }
}

async function boot(): Promise<void> {
  const bridge = window.xray ?? mockBridge();
  document.documentElement.classList.add(`platform-${navigator.userAgent.includes("Windows") ? "win32" : "other"}`);
  window.__xrayPrepareExport = prepareExport;
  window.__xrayFinishExport = finishExport;
  window.__xrayNavigate = navigate;
  render(<App />, document.getElementById("app")!);
  bridge.onNavigate(navigate);
  await store.start(bridge);
  document.documentElement.classList.toggle("popup-window", store.isPopup);
  if (!window.xray) {
    // Dev harness: #screen=overview&period=week&tab=flow
    const params = new URLSearchParams(location.hash.slice(1));
    navigate({ screen: params.get("screen") ?? undefined, tab: params.get("tab") ?? undefined, period: params.get("period") ?? undefined, scroll: params.get("scroll") ?? undefined });
  }
  document.documentElement.dataset.ready = "1";
}

void boot();
