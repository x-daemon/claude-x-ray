// Claude Code status line: the command mode (S2A Claude X-Ray.exe --statusline) and the installer
// that adds it to Claude Code's settings.json. Port of App/StatusLine.swift.
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { planUsageFromStatusLine, statusLineSummary } from "../core/plan";
import type { StatusLineState } from "../shared/api";
import { L, resolveLanguage, setLanguage, type Language } from "../core/i18n";
import { loadPlanUsage, loadSettings, Paths, readJSON, savePlanUsage, writeJSON } from "./store";

export const STATUSLINE_FLAG = "--statusline";

interface StatusLineConfig {
  /** The status line command the user had before; X-Ray runs it and shows its output. */
  wrappedCommand?: string;
  installedAt: string;
}

const loadConfig = (): StatusLineConfig | undefined => readJSON<StatusLineConfig>(Paths.statusLineConfig);

function readStdin(): string {
  try {
    return readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

/** Bash that Claude Code uses on Windows (Git Bash), for running the user's own status line. */
function gitBash(): string | undefined {
  const candidates = [
    process.env.CLAUDE_CODE_GIT_BASH_PATH,
    "C:\\Program Files\\Git\\bin\\bash.exe",
    "C:\\Program Files (x86)\\Git\\bin\\bash.exe",
    path.join(os.homedir(), "AppData", "Local", "Programs", "Git", "bin", "bash.exe"),
  ];
  return candidates.find((c): c is string => !!c && existsSync(c));
}

function runWrapped(command: string, input: string): string {
  const options = { input, encoding: "utf8" as const, timeout: 10_000, windowsHide: true };
  const bash = process.platform === "win32" ? gitBash() : "/bin/sh";
  const result = bash ? spawnSync(bash, ["-c", command], options) : spawnSync(command, { ...options, shell: true });
  return typeof result.stdout === "string" ? result.stdout : "";
}

/**
 * Claude Code runs this after every response and passes session data, including the account's
 * plan usage, on stdin. Saves the plan usage for the app and prints a status line (or the user's
 * own status line, which it wraps).
 */
export function runStatusLine(): string {
  // The line is written in the interface language, like the app (this mode starts no UI).
  const lang = process.env.XRAY_SNAPSHOT_LANGUAGE as Language | undefined;
  setLanguage(lang ?? resolveLanguage(loadSettings().language, [Intl.DateTimeFormat().resolvedOptions().locale]));
  const input = readStdin();
  const now = Date.now();
  let usage = loadPlanUsage();
  const fresh = planUsageFromStatusLine(input, now);
  if (fresh) {
    try {
      usage = savePlanUsage(fresh);
    } catch {
      // A broken status line would show in every Claude Code session: never fail loudly.
    }
  }
  const wrapped = loadConfig()?.wrappedCommand;
  return wrapped ? runWrapped(wrapped, input) : statusLineSummary(input, usage, now) + "\n";
}

// MARK: Installer

/** Claude Code's user settings: in CLAUDE_CONFIG_DIR when set, otherwise ~/.claude. */
export function claudeSettingsPath(): string {
  const configured = (process.env.CLAUDE_CONFIG_DIR ?? "").split(",")[0]?.trim();
  if (configured) return path.join(configured.startsWith("~") ? path.join(os.homedir(), configured.slice(1)) : configured, "settings.json");
  return path.join(os.homedir(), ".claude", "settings.json");
}

/** The command Claude Code runs: this app's executable with --statusline (forward slashes work in bash and cmd). */
export function statusLineCommand(executable = process.execPath): string {
  return `"${executable.replace(/\\/g, "/")}" ${STATUSLINE_FLAG}`;
}

export const isOurs = (command: string): boolean => command.includes(STATUSLINE_FLAG) && /S2A|x-ray|xray/i.test(command);

type Json = Record<string, unknown>;

function readSettings(): Json {
  const file = claudeSettingsPath();
  if (!existsSync(file)) return {};
  const text = readFileSync(file, "utf8");
  if (!text.trim()) return {};
  const parsed = JSON.parse(text) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(L`settings.json не похож на настройки Claude Code (ожидался JSON-объект). X-Ray его не меняет.`);
  }
  return parsed as Json;
}

/** Writes settings.json after copying the current one to settings.json.xray-backup. */
function writeSettings(settings: Json): void {
  const file = claudeSettingsPath();
  if (existsSync(file)) copyFileSync(file, file + ".xray-backup");
  writeJSON(file, settings);
}

export function statusLineState(): StatusLineState {
  let settings: Json;
  try {
    settings = readSettings();
  } catch (error) {
    return { type: "unreadable", message: (error as Error).message };
  }
  const statusLine = settings.statusLine as Json | undefined;
  const command = typeof statusLine?.command === "string" ? statusLine.command : "";
  if (!command) return { type: "notInstalled" };
  if (isOurs(command)) return { type: "installed", wrapping: loadConfig()?.wrappedCommand };
  return { type: "otherStatusLine", command };
}

export function installStatusLine(executable = process.execPath): void {
  const settings = readSettings();
  const statusLine = { ...((settings.statusLine as Json | undefined) ?? {}) };
  let wrapped = loadConfig()?.wrappedCommand;
  const current = typeof statusLine.command === "string" ? statusLine.command : "";
  if (current && !isOurs(current)) wrapped = current;
  const config: StatusLineConfig = { wrappedCommand: wrapped, installedAt: new Date().toISOString() };
  writeJSON(Paths.statusLineConfig, config);
  statusLine.type = "command";
  statusLine.command = statusLineCommand(executable);
  settings.statusLine = statusLine;
  writeSettings(settings);
}

export function uninstallStatusLine(): void {
  const settings = readSettings();
  const statusLine = settings.statusLine as Json | undefined;
  if (statusLine && typeof statusLine.command === "string" && isOurs(statusLine.command)) {
    const wrapped = loadConfig()?.wrappedCommand;
    if (wrapped) settings.statusLine = { ...statusLine, command: wrapped };
    else delete settings.statusLine;
    writeSettings(settings);
  }
  rmSync(Paths.statusLineConfig, { force: true });
}
