// Files X-Ray keeps in %APPDATA%\S2AClaudeXRay (Application Support on macOS, ~/.config on Linux),
// settings and the price list.
import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { mergePlanUsage, type PlanUsage } from "../core/plan";
import { defaultPricing, mergingMissingDefaults, type PricingTable } from "../core/pricing";
import type { Settings } from "../shared/api";

/** Same folder Electron's app.getPath("appData") gives, so the status line mode finds it without Electron. */
export function appDataDir(): string {
  if (process.platform === "win32") return process.env.APPDATA ?? path.join(os.homedir(), "AppData", "Roaming");
  if (process.platform === "darwin") return path.join(os.homedir(), "Library", "Application Support");
  return process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config");
}

export const Paths = {
  get support(): string {
    return process.env.XRAY_SUPPORT_DIR ?? path.join(appDataDir(), "S2AClaudeXRay");
  },
  get settings(): string { return path.join(Paths.support, "settings.json"); },
  get pricing(): string { return path.join(Paths.support, "pricing.json"); },
  get planUsage(): string { return path.join(Paths.support, "plan-usage.json"); },
  get statusLineConfig(): string { return path.join(Paths.support, "statusline.json"); },
  get receiverToken(): string { return path.join(Paths.support, "receiver-token"); },
  get imported(): string { return path.join(Paths.support, "imported"); },
  get cloud(): string { return path.join(Paths.support, "cloud"); },
};

export function readJSON<T>(file: string): T | undefined {
  try {
    return JSON.parse(readFileSync(file, "utf8")) as T;
  } catch {
    return undefined;
  }
}

/** Writes through a temporary file so a crash never leaves half a file. */
export function writeJSON(file: string, value: unknown): void {
  mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.tmp`;
  writeFileSync(temp, JSON.stringify(value, null, 2) + "\n", "utf8");
  renameSync(temp, file);
}

export const defaultSettings = (): Settings => ({
  plan: "max5x",
  theme: "s2a",
  appearance: "auto",
  language: "system",
  receiverEnabled: false,
  receiverPort: 47318,
  hideContent: false,
});

export function loadSettings(): Settings {
  const saved = readJSON<Partial<Settings>>(Paths.settings);
  // Settings saved before the language setting existed: keep the Russian interface they had.
  return { ...defaultSettings(), ...(saved ? { language: "ru" as const } : {}), ...(saved ?? {}) };
}

export function saveSettings(settings: Settings): void {
  writeJSON(Paths.settings, settings);
}

export function loadPricing(): PricingTable {
  const saved = readJSON<PricingTable>(Paths.pricing);
  return saved?.models ? mergingMissingDefaults(saved) : defaultPricing();
}

export function savePricing(table: PricingTable | null): PricingTable {
  if (!table) {
    writeJSON(Paths.pricing, defaultPricing());
    return defaultPricing();
  }
  writeJSON(Paths.pricing, table);
  return table;
}

export function loadPlanUsage(): PlanUsage | undefined {
  return readJSON<PlanUsage>(Paths.planUsage);
}

export function savePlanUsage(fresh: PlanUsage): PlanUsage {
  const merged = mergePlanUsage(fresh, loadPlanUsage());
  writeJSON(Paths.planUsage, merged);
  return merged;
}

/** The access token cloud uploads must send as Authorization: Bearer <token>; created on first use. */
export function loadOrCreateToken(): string {
  try {
    const existing = readFileSync(Paths.receiverToken, "utf8").trim();
    if (existing.length >= 32) return existing;
  } catch {
    // create below
  }
  return createToken();
}

export function createToken(): string {
  const token = "xray_" + randomBytes(32).toString("hex");
  mkdirSync(Paths.support, { recursive: true });
  writeFileSync(Paths.receiverToken, token, { encoding: "utf8", mode: 0o600 });
  try {
    chmodSync(Paths.receiverToken, 0o600);
  } catch {
    // Windows ignores POSIX modes; the file sits in the user's own profile.
  }
  return token;
}

export const exists = (p: string): boolean => existsSync(p);
