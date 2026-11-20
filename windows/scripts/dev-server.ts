// Dev harness: serves the built renderer (dist/renderer) in a browser with the state the main
// process would send, built from a folder of transcripts. No Electron needed, so the UI can be
// checked with Playwright on any OS.
//   npx tsx scripts/dev-server.ts <CLAUDE_CONFIG_DIR with projects/> [port]
// Then open http://127.0.0.1:<port>/#screen=overview&theme=s2a&mode=dark&period=week
import { createServer } from "node:http";
import { existsSync, readFileSync } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { LANGUAGES, setLanguage, type Language } from "../src/core/i18n";
import { TranscriptIngestor } from "../src/core/ingest";
import type { PlanUsage } from "../src/core/plan";
import { defaultPricing } from "../src/core/pricing";
import type { InitialState } from "../src/shared/api";

const [dataDir = path.join(os.homedir(), ".claude"), portText = "5173"] = process.argv.slice(2);
const root = path.join(__dirname, "..", "dist", "renderer");
const projects = path.join(dataDir, "projects");

async function state(language: Language): Promise<InitialState> {
  // Activity titles and default price notes are written in the language they are read in.
  setLanguage(language);
  const now = Date.now();
  const result = await new TranscriptIngestor().scan([projects], now - 3 * 86_400_000);
  const planUsage: PlanUsage = {
    capturedAt: now - 4 * 60_000,
    fiveHour: { usedPercentage: 37.5, resetsAt: now + 7800_000 },
    sevenDay: { usedPercentage: 22, resetsAt: now + 3 * 86_400_000 + 5000_000 },
    model: "Opus 5.5",
    version: "2.1.325",
  };
  return {
    settings: { plan: "max5x", theme: "s2a", appearance: "light", language, receiverEnabled: true, receiverPort: 47318, hideContent: false, viewerEnabled: true, viewerAddress: "" },
    directories: [projects],
    pricing: defaultPricing(),
    planUsage,
    statusLine: { type: "installed" },
    statusLineSettingsPath: path.join(os.homedir(), ".claude", "settings.json"),
    receiver: { listening: true, port: 47318, uploads: 3, lines: 412, lastUpload: now - 90_000, lastPath: "cloud/demo/session.jsonl", rejectedAuth: 0, viewerRequests: 128, lastViewerRequest: now - 4_000, viewerRejected: 0 },
    receiverToken: "xray_3f9c2a7d41e0b8c65a1f2e9d7c3b4a5f60718293a4b5c6d7e8f9012345678",
    viewerToken: "xrayv_8e1d4c7b2a9f0e3d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a3928170",
    computerName: "XDAEMON-PC",
    detectedAddress: "https://xdaemon-pc.tailnet-demo.ts.net",
    events: result.events,
    activities: result.activities,
    scan: { scanning: false, lastScan: now, filesSeen: result.filesSeen, linesRead: result.linesRead, duration: result.duration, errors: result.errors, sources: result.sources },
    platform: "win32",
    version: "0.6.0",
    supportDir: path.join(os.homedir(), "AppData", "Roaming", "S2AClaudeXRay"),
    homeDir: os.homedir(),
    isPopup: false,
    language,
  };
}

const types: Record<string, string> = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8" };

createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (url.pathname === "/api/init") {
    res.writeHead(200, { "content-type": "application/json" });
    const lang = url.searchParams.get("lang") as Language | null;
    res.end(JSON.stringify(await state(lang && LANGUAGES.includes(lang) ? lang : "ru")));
    return;
  }
  const file = path.join(root, url.pathname === "/" ? "index.html" : path.normalize(url.pathname).replace(/^([\\/])+/, ""));
  if (!file.startsWith(root) || !existsSync(file)) {
    res.writeHead(404).end("not found");
    return;
  }
  res.writeHead(200, { "content-type": types[path.extname(file)] ?? "application/octet-stream" });
  res.end(readFileSync(file));
}).listen(Number(portText), "127.0.0.1", () => console.log(`dev harness on http://127.0.0.1:${portText}/ reading ${projects}`));
