// Electron main process: windows, tray, IPC, scanning, the receiver and the status line mode.
import { STATUSLINE_FLAG, runStatusLine } from "./statusline";

// The status line mode must not start any UI: Claude Code runs it after every response.
const statusLineMode = process.argv.includes(STATUSLINE_FLAG);
if (statusLineMode) {
  const text = runStatusLine();
  process.stdout.write(text, () => process.exit(0));
}

import { app, BrowserWindow, clipboard, dialog, ipcMain, Menu, nativeImage, nativeTheme, screen, shell, Tray, type IpcMainInvokeEvent } from "electron";
import { existsSync, mkdirSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { Fmt } from "../core/fmt";
import { windowFraction, windowHasReset, type PlanUsage } from "../core/plan";
import { CHANNELS, type Delta, type InitialState, type ReceiverStatus, type Settings } from "../shared/api";
import { TranscriptReceiver } from "./receiver";
import { IngestService } from "./service";
import { claudeSettingsPath, installStatusLine, statusLineState, uninstallStatusLine } from "./statusline";
import { createToken, loadOrCreateToken, loadPlanUsage, loadPricing, loadSettings, Paths, saveSettings, savePricing } from "./store";

const isSnapshot = !!process.env.XRAY_SNAPSHOT_DIR;
const appRoot = path.join(__dirname, "..");
const iconPath = path.join(appRoot, "assets", "icon.png");
/** 16 px tray icon; tray@2x.png next to it is picked up on high-DPI screens. */
const trayIconPath = path.join(appRoot, "assets", "tray.png");
/** Height of the renderer's top bar (--topbar in styles.css), where the window buttons sit. */
const TITLE_BAR_HEIGHT = 44;

let settings: Settings = loadSettings();
if (process.env.XRAY_RECEIVER_PORT && process.env.XRAY_RECEIVER_TOKEN) {
  settings = { ...settings, receiverEnabled: true, receiverPort: Number(process.env.XRAY_RECEIVER_PORT) };
}
let pricing = loadPricing();
let planUsage: PlanUsage | undefined = loadPlanUsage();
let receiverToken = "";
let mainWindow: BrowserWindow | undefined;
let popup: BrowserWindow | undefined;
let tray: Tray | undefined;
let quitting = false;
let supportWatcher: FSWatcher | undefined;

const windows = (): BrowserWindow[] => [mainWindow, popup].filter((w): w is BrowserWindow => !!w && !w.isDestroyed());
const send = (channel: string, payload: unknown): void => {
  for (const w of windows()) w.webContents.send(channel, payload);
};

const service = new IngestService(settings.directories, (delta: Delta) => {
  send(CHANNELS.delta, delta);
  updateTray();
});

const receiver = new TranscriptReceiver((status: ReceiverStatus) => send(CHANNELS.receiver, status));

function startReceiver(): void {
  if (settings.receiverEnabled) {
    service.ensureCloudFolder();
    receiver.start(settings.receiverPort, receiverToken);
  } else {
    receiver.stop();
  }
}

// MARK: Theme

function isDark(): boolean {
  return settings.appearance === "dark" || (settings.appearance === "auto" && nativeTheme.shouldUseDarkColors);
}

function chrome(): { background: string; symbol: string } {
  if (settings.theme === "s2a") return isDark() ? { background: "#101129", symbol: "#e7e6f7" } : { background: "#eeedf8", symbol: "#2b2850" };
  return isDark() ? { background: "#202020", symbol: "#ffffff" } : { background: "#f3f3f3", symbol: "#1b1b1b" };
}

function applyTheme(): void {
  nativeTheme.themeSource = settings.appearance === "auto" ? "system" : settings.appearance;
  const colors = chrome();
  for (const w of windows()) {
    w.setBackgroundColor(colors.background);
    if (w === mainWindow && process.platform !== "darwin") {
      try {
        w.setTitleBarOverlay({ color: colors.background, symbolColor: colors.symbol, height: TITLE_BAR_HEIGHT });
      } catch {
        // not available on this platform
      }
    }
  }
}

// MARK: Windows

function createMainWindow(): BrowserWindow {
  const colors = chrome();
  const win = new BrowserWindow({
    width: 1240,
    height: 820,
    minWidth: 980,
    minHeight: 640,
    show: false,
    title: "S2A Claude X-Ray",
    icon: iconPath,
    backgroundColor: colors.background,
    titleBarStyle: "hidden",
    ...(process.platform === "darwin" ? { trafficLightPosition: { x: 14, y: 14 } } : { titleBarOverlay: { color: colors.background, symbolColor: colors.symbol, height: TITLE_BAR_HEIGHT } }),
    webPreferences: { preload: path.join(appRoot, "dist", "preload.js"), contextIsolation: true, sandbox: false, nodeIntegration: false },
  });
  win.removeMenu();
  void win.loadFile(path.join(appRoot, "dist", "renderer", "index.html"));
  win.once("ready-to-show", () => {
    if (!isSnapshot && !process.argv.includes("--hidden")) win.show();
  });
  // Closing the window keeps the tray monitor running.
  win.on("close", (event) => {
    if (!quitting && !isSnapshot) {
      event.preventDefault();
      win.hide();
    }
  });
  win.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: "deny" };
  });
  return win;
}

function showMain(screenName?: string): void {
  if (!mainWindow || mainWindow.isDestroyed()) mainWindow = createMainWindow();
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
  if (screenName) mainWindow.webContents.send(CHANNELS.navigate, { screen: screenName });
}

function createPopup(): BrowserWindow {
  const win = new BrowserWindow({
    width: 380,
    height: 560,
    show: false,
    frame: false,
    resizable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    backgroundColor: chrome().background,
    webPreferences: { preload: path.join(appRoot, "dist", "preload.js"), contextIsolation: true, sandbox: false },
  });
  void win.loadFile(path.join(appRoot, "dist", "renderer", "index.html"), { query: { popup: "1" } });
  win.on("blur", () => win.hide());
  return win;
}

function togglePopup(): void {
  if (!popup || popup.isDestroyed()) popup = createPopup();
  if (popup.isVisible()) {
    popup.hide();
    return;
  }
  const trayBounds = tray?.getBounds();
  const display = screen.getDisplayNearestPoint(trayBounds ? { x: trayBounds.x, y: trayBounds.y } : screen.getCursorScreenPoint());
  const area = display.workArea;
  const [width, height] = popup.getSize();
  const x = Math.min(Math.max((trayBounds?.x ?? area.x + area.width) - width / 2, area.x + 8), area.x + area.width - width - 8);
  const taskbarAtTop = trayBounds ? trayBounds.y < area.y + area.height / 2 : false;
  const y = taskbarAtTop ? area.y + 8 : area.y + area.height - height - 8;
  popup.setPosition(Math.round(x), Math.round(y));
  popup.show();
  popup.focus();
}

// MARK: Tray

/** Set by the main window's renderer, which prices the usage; plan usage alone until then. */
let rendererTrayTitle: string | undefined;

function trayTitle(): string {
  if (rendererTrayTitle) return rendererTrayTitle.slice(0, 127);
  const parts: string[] = [];
  const now = Date.now();
  if (planUsage?.fiveHour && now - planUsage.capturedAt < 3 * 3_600_000 && !windowHasReset(planUsage.fiveHour, now)) {
    parts.push(`лимит 5 ч ${Fmt.percent(windowFraction(planUsage.fiveHour, now))}`);
  }
  return ["S2A Claude X-Ray", ...parts].join(" · ");
}

function updateTray(): void {
  tray?.setToolTip(trayTitle());
}

function createTray(): void {
  tray = new Tray(nativeImage.createFromPath(trayIconPath));
  tray.setToolTip(trayTitle());
  tray.on("click", togglePopup);
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: "Открыть X-Ray", click: () => showMain() },
    { label: "Обновить данные", click: () => void service.rescan() },
    { label: "Настройки", click: () => showMain("settings") },
    { type: "separator" },
    { label: "Выйти", click: () => { quitting = true; app.quit(); } },
  ]));
}

// MARK: IPC

function initialState(event: IpcMainInvokeEvent): InitialState {
  const snapshot = service.snapshot();
  return {
    settings,
    directories: service.directories,
    pricing,
    planUsage,
    statusLine: statusLineState(),
    statusLineSettingsPath: claudeSettingsPath(),
    receiver: receiver.status,
    receiverToken,
    events: snapshot.events,
    activities: snapshot.activities,
    scan: service.scan,
    platform: process.platform,
    version: app.getVersion(),
    supportDir: Paths.support,
    homeDir: os.homedir(),
    isPopup: !!popup && event.sender === popup.webContents,
  };
}

function broadcastSettings(): void {
  send(CHANNELS.settings, { settings, directories: service.directories });
}

function registerIPC(): void {
  ipcMain.handle(CHANNELS.init, (event) => initialState(event));
  ipcMain.handle(CHANNELS.rescan, () => service.rescan());
  ipcMain.handle(CHANNELS.fullRescan, () => service.fullRescan());
  ipcMain.handle(CHANNELS.updateSettings, (_e, patch: Partial<Settings>) => {
    const previous = settings;
    settings = { ...settings, ...patch };
    saveSettings(settings);
    if (patch.theme !== undefined || patch.appearance !== undefined) applyTheme();
    if (patch.receiverEnabled !== undefined || (patch.receiverPort !== undefined && patch.receiverPort !== previous.receiverPort)) startReceiver();
    broadcastSettings();
    return settings;
  });
  ipcMain.handle(CHANNELS.setDirectories, (_e, directories: string[] | null) => {
    settings = { ...settings, directories: directories ?? undefined };
    saveSettings(settings);
    service.setDirectories(settings.directories);
    broadcastSettings();
    return service.directories;
  });
  ipcMain.handle(CHANNELS.pickFolder, async () => {
    const result = await dialog.showOpenDialog(mainWindow!, { properties: ["openDirectory", "showHiddenFiles"], title: "Папка с транскриптами Claude Code" });
    return result.canceled ? undefined : result.filePaths[0];
  });
  ipcMain.handle(CHANNELS.setPricing, (_e, table) => {
    pricing = savePricing(table);
    return pricing;
  });
  ipcMain.handle(CHANNELS.statusLineState, () => statusLineState());
  ipcMain.handle(CHANNELS.installStatusLine, () => {
    try {
      installStatusLine();
      return { state: statusLineState() };
    } catch (error) {
      return { state: statusLineState(), error: (error as Error).message };
    }
  });
  ipcMain.handle(CHANNELS.uninstallStatusLine, () => {
    try {
      uninstallStatusLine();
      return { state: statusLineState() };
    } catch (error) {
      return { state: statusLineState(), error: (error as Error).message };
    }
  });
  ipcMain.handle(CHANNELS.importDialog, async () => {
    const result = await dialog.showOpenDialog(mainWindow!, {
      title: "Импортировать лог сессии",
      properties: ["openFile", "multiSelections"],
      filters: [{ name: "Логи Claude Code", extensions: ["jsonl", "zip"] }],
    });
    return result.canceled ? 0 : service.importFiles(result.filePaths);
  });
  ipcMain.handle(CHANNELS.importPaths, (_e, paths: string[]) => service.importFiles(paths));
  ipcMain.handle(CHANNELS.regenerateToken, () => {
    receiverToken = createToken();
    startReceiver();
    return receiverToken;
  });
  ipcMain.handle(CHANNELS.savePDF, async (event, name: string, size?: { width: number; height: number }) => {
    const win = BrowserWindow.fromWebContents(event.sender) ?? mainWindow!;
    const data = await printReport(event.sender, size);
    const result = await dialog.showSaveDialog(win, { defaultPath: name, filters: [{ name: "PDF", extensions: ["pdf"] }] });
    if (result.canceled || !result.filePath) return undefined;
    writeFileSync(result.filePath, data);
    shell.showItemInFolder(result.filePath);
    return result.filePath;
  });
  ipcMain.handle(CHANNELS.saveText, async (event, name: string, text: string, kind: "md" | "csv") => {
    const win = BrowserWindow.fromWebContents(event.sender) ?? mainWindow!;
    const filters = kind === "md" ? [{ name: "Markdown", extensions: ["md"] }] : [{ name: "CSV", extensions: ["csv"] }];
    const result = await dialog.showSaveDialog(win, { defaultPath: name, filters });
    if (result.canceled || !result.filePath) return undefined;
    // CSV with a BOM so Excel on Windows reads Cyrillic correctly.
    writeFileSync(result.filePath, (kind === "csv" ? "﻿" : "") + text, "utf8");
    return result.filePath;
  });
  ipcMain.handle(CHANNELS.copyText, (_e, text: string) => clipboard.writeText(text));
  ipcMain.handle(CHANNELS.openPath, async (_e, target: string) => {
    if (existsSync(target)) await shell.openPath(target);
  });
  ipcMain.handle(CHANNELS.openExternal, (_e, url: string) => {
    if (/^https:\/\//.test(url)) void shell.openExternal(url);
  });
  ipcMain.handle(CHANNELS.openMain, (_e, screenName?: string) => {
    popup?.hide();
    showMain(screenName);
  });
  ipcMain.on(CHANNELS.trayTitle, (event, text: string) => {
    if (mainWindow && event.sender === mainWindow.webContents && typeof text === "string") {
      rendererTrayTitle = text;
      updateTray();
    }
  });
  ipcMain.handle(CHANNELS.quit, () => {
    quitting = true;
    app.quit();
  });
}

/**
 * Prints the page to PDF. With a size (CSS px, set by the renderer as an @page rule too) the
 * report becomes one long page, like the macOS app's PDF; otherwise A4 pages.
 */
function printReport(contents: Electron.WebContents, size?: { width: number; height: number }): Promise<Buffer> {
  if (size && size.width > 0 && size.height > 0) {
    return contents.printToPDF({
      printBackground: true,
      preferCSSPageSize: true,
      pageSize: { width: size.width / 96, height: size.height / 96 },
      margins: { top: 0, bottom: 0, left: 0, right: 0 },
    });
  }
  return contents.printToPDF({ printBackground: true, pageSize: "A4", margins: { top: 0.4, bottom: 0.4, left: 0.4, right: 0.4 } });
}

// MARK: Plan usage file

function watchPlanUsage(): void {
  mkdirSync(Paths.support, { recursive: true });
  const reload = () => {
    const next = loadPlanUsage();
    if (JSON.stringify(next) !== JSON.stringify(planUsage)) {
      planUsage = next;
      send(CHANNELS.planUsage, planUsage);
      updateTray();
    }
  };
  try {
    supportWatcher = watch(Paths.support, (_event, file) => {
      if (String(file) === path.basename(Paths.planUsage)) setTimeout(reload, 100);
    });
  } catch {
    // fall back to polling below
  }
  setInterval(reload, 15_000);
}

// MARK: Snapshot mode (CI)

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function runSnapshots(dir: string): Promise<void> {
  mkdirSync(dir, { recursive: true });
  const log: string[] = [];
  const win = mainWindow!;
  win.setSize(1440, 1000);
  win.show();
  for (let i = 0; i < 120 && !service.scan.lastScan; i++) await sleep(250);
  await sleep(1500);
  log.push(`events: ${service.usage.count}, activity items: ${service.activity.count}, files: ${service.scan.filesSeen}`);
  const screens = (process.env.XRAY_SNAPSHOT_SCREENS ?? "live,trace,overview,sessions,projects,models,insights,reports,settings").split(",");
  const tabs = ["feed", "flow", "llm", "timeline", "context", "tools"];
  const passes: { theme: Settings["theme"]; appearance: Settings["appearance"]; name: string; screens: string[] }[] = [
    { theme: "s2a", appearance: "light", name: "s2a-light", screens },
    { theme: "s2a", appearance: "dark", name: "s2a-dark", screens },
    { theme: "system", appearance: "light", name: "system-light", screens: screens.filter((s) => ["live", "trace", "overview"].includes(s)) },
  ];
  for (const pass of passes) {
    settings = { ...settings, theme: pass.theme, appearance: pass.appearance };
    applyTheme();
    broadcastSettings();
    await sleep(600);
    for (const screenName of pass.screens) {
      const shots = screenName === "trace" ? tabs.map((tab) => ({ tab, name: `${pass.name}-trace-${tab}` })) : [{ tab: undefined, name: `${pass.name}-${screenName}` }];
      for (const shot of shots) {
        win.webContents.send(CHANNELS.navigate, { screen: screenName, tab: shot.tab, period: screenName === "reports" ? "week" : "month" });
        await sleep(1400);
        const image = await win.webContents.capturePage();
        writeFileSync(path.join(dir, `${shot.name}.png`), image.toPNG());
        log.push(`${shot.name}: ${image.getSize().width}x${image.getSize().height}`);
        if (screenName === "live") {
          win.webContents.send(CHANNELS.navigate, { scroll: "bottom" });
          await sleep(500);
          writeFileSync(path.join(dir, `${shot.name}-bottom.png`), (await win.webContents.capturePage()).toPNG());
          win.webContents.send(CHANNELS.navigate, { scroll: "top" });
        }
      }
    }
  }
  if (screens.includes("reports")) {
    settings = { ...settings, theme: "s2a", appearance: "light" };
    applyTheme();
    broadcastSettings();
    win.webContents.send(CHANNELS.navigate, { screen: "reports", period: "week" });
    await sleep(1500);
    const size = (await win.webContents.executeJavaScript("window.__xrayPrepareExport ? window.__xrayPrepareExport() : undefined")) as { width: number; height: number } | undefined;
    const pdf = await printReport(win.webContents, size);
    await win.webContents.executeJavaScript("window.__xrayFinishExport && window.__xrayFinishExport()");
    writeFileSync(path.join(dir, "report.pdf"), pdf);
    log.push(`report.pdf: ${pdf.length} bytes, page ${size ? `${size.width}x${size.height} px` : "A4"}`);
  }
  writeFileSync(path.join(dir, "snapshots.log"), log.join("\n") + "\n");
  quitting = true;
  app.quit();
}

// MARK: Lifecycle

if (statusLineMode) {
  // handled at the top
} else if (!isSnapshot && !app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => showMain());
  app.setAppUserModelId("com.s2a.claude-xray");
  app.whenReady().then(() => {
    receiverToken = process.env.XRAY_RECEIVER_TOKEN ?? loadOrCreateToken();
    registerIPC();
    applyTheme();
    nativeTheme.on("updated", () => {
      applyTheme();
      broadcastSettings();
    });
    mainWindow = createMainWindow();
    if (!isSnapshot) createTray();
    service.start();
    startReceiver();
    watchPlanUsage();
    if (isSnapshot) void runSnapshots(process.env.XRAY_SNAPSHOT_DIR!);
  });
  app.on("before-quit", () => {
    quitting = true;
    service.stop();
    receiver.stop(false);
    supportWatcher?.close();
  });
  app.on("window-all-closed", () => {
    if (isSnapshot) app.quit();
    // Otherwise keep running in the tray.
  });
}
