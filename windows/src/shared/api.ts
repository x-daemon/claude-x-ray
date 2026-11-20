// Types shared by the main process, the preload bridge and the renderer.
import type { ActivityItem } from "../core/activity";
import type { SourceStat } from "../core/ingest";
import type { Language, LanguageSetting } from "../core/i18n";
import type { UsageEvent } from "../core/model";
import type { PlanUsage } from "../core/plan";
import type { PricingTable } from "../core/pricing";

export type ThemeName = "s2a" | "system";
export type Appearance = "auto" | "light" | "dark";
export type SubscriptionPlan = "pro" | "max5x" | "max20x" | "api";

export interface Settings {
  /** Transcript folders; undefined means the defaults (~/.claude/projects...). */
  directories?: string[];
  plan: SubscriptionPlan;
  theme: ThemeName;
  appearance: Appearance;
  /** Interface language; "system" follows Windows. */
  language: LanguageSetting;
  receiverEnabled: boolean;
  receiverPort: number;
  hideContent: boolean;
  /** Read-only access for X-Ray on the iPad, with its own token. */
  viewerEnabled: boolean;
  /** The address the iPad reaches this computer at, as typed; empty uses the detected one. */
  viewerAddress: string;
}

export type StatusLineState =
  | { type: "notInstalled" }
  | { type: "otherStatusLine"; command: string }
  | { type: "installed"; wrapping?: string }
  | { type: "unreadable"; message: string };

export interface ReceiverStatus {
  listening: boolean;
  port: number;
  error?: string;
  uploads: number;
  lines: number;
  lastUpload?: number;
  lastPath?: string;
  rejectedAuth: number;
  /** Requests of the iPad app. */
  viewerRequests: number;
  lastViewerRequest?: number;
  viewerRejected: number;
}

export interface ScanInfo {
  scanning: boolean;
  lastScan?: number;
  filesSeen: number;
  linesRead: number;
  duration: number;
  errors: string[];
  sources: SourceStat[];
}

/** Everything a new window needs. */
export interface InitialState {
  settings: Settings;
  directories: string[];
  pricing: PricingTable;
  planUsage?: PlanUsage;
  statusLine: StatusLineState;
  statusLineSettingsPath: string;
  receiver: ReceiverStatus;
  receiverToken: string;
  viewerToken: string;
  /** This computer's name, which the iPad shows. */
  computerName: string;
  /** This computer's Tailscale address, when Tailscale is installed. */
  detectedAddress?: string;
  events: UsageEvent[];
  activities: ActivityItem[];
  scan: ScanInfo;
  platform: string;
  version: string;
  supportDir: string;
  homeDir: string;
  isPopup: boolean;
  /** The interface language in effect ("system" resolved). */
  language: Language;
}

/** Pushed to every window after each scan. */
export interface Delta {
  events: UsageEvent[];
  activities: ActivityItem[];
  scan: ScanInfo;
  /** True after a full rescan: drop what you have first. */
  reset?: boolean;
}

/** The bridge exposed to the renderer as window.xray. */
export interface XRayBridge {
  init(): Promise<InitialState>;
  onDelta(callback: (delta: Delta) => void): void;
  onPlanUsage(callback: (usage: PlanUsage | undefined) => void): void;
  onReceiver(callback: (status: ReceiverStatus) => void): void;
  onSettings(callback: (settings: Settings, directories: string[], language: Language) => void): void;
  onNavigate(callback: (target: { screen?: string; tab?: string; period?: string }) => void): void;
  rescan(): Promise<void>;
  fullRescan(): Promise<void>;
  updateSettings(patch: Partial<Settings>): Promise<Settings>;
  setDirectories(directories: string[] | null): Promise<string[]>;
  pickFolder(): Promise<string | undefined>;
  setPricing(table: PricingTable | null): Promise<PricingTable>;
  statusLineState(): Promise<StatusLineState>;
  installStatusLine(): Promise<{ state: StatusLineState; error?: string }>;
  uninstallStatusLine(): Promise<{ state: StatusLineState; error?: string }>;
  importDialog(): Promise<number>;
  importPaths(paths: string[]): Promise<number>;
  pathForFile(file: File): string;
  regenerateToken(): Promise<string>;
  regenerateViewerToken(): Promise<string>;
  /** Looks up this computer's Tailscale address. */
  detectAddress(): Promise<string | undefined>;
  /** Prints the current page to a PDF; `size` (CSS px) makes it one page of that size. */
  savePDF(name: string, size?: { width: number; height: number }): Promise<string | undefined>;
  saveText(name: string, text: string, kind: "md" | "csv"): Promise<string | undefined>;
  copyText(text: string): Promise<void>;
  openPath(target: string): Promise<void>;
  openExternal(url: string): Promise<void>;
  openMain(screen?: string): Promise<void>;
  /** Text of the tray icon tooltip (the menu bar title of the macOS app). */
  setTrayTitle(text: string): void;
  quit(): Promise<void>;
}

export const CHANNELS = {
  init: "xray:init",
  delta: "xray:delta",
  planUsage: "xray:plan-usage",
  receiver: "xray:receiver",
  settings: "xray:settings",
  navigate: "xray:navigate",
  rescan: "xray:rescan",
  fullRescan: "xray:full-rescan",
  updateSettings: "xray:update-settings",
  setDirectories: "xray:set-directories",
  pickFolder: "xray:pick-folder",
  setPricing: "xray:set-pricing",
  statusLineState: "xray:status-line-state",
  installStatusLine: "xray:install-status-line",
  uninstallStatusLine: "xray:uninstall-status-line",
  importDialog: "xray:import-dialog",
  importPaths: "xray:import-paths",
  regenerateToken: "xray:regenerate-token",
  regenerateViewerToken: "xray:regenerate-viewer-token",
  detectAddress: "xray:detect-address",
  savePDF: "xray:save-pdf",
  saveText: "xray:save-text",
  copyText: "xray:copy-text",
  openPath: "xray:open-path",
  openExternal: "xray:open-external",
  openMain: "xray:open-main",
  trayTitle: "xray:tray-title",
  quit: "xray:quit",
} as const;
