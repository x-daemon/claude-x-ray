// Bridge for the browser dev harness (scripts/dev-server.ts): the renderer runs outside Electron,
// reads its initial state over HTTP and keeps settings in memory. Not used by the app itself.
import { defaultPricing, type PricingTable } from "../core/pricing";
import type { InitialState, Settings, StatusLineState, XRayBridge } from "../shared/api";

export function mockBridge(): XRayBridge {
  const params = new URLSearchParams(location.hash.slice(1));
  let state: InitialState | undefined;
  let settings: Settings | undefined;
  let statusLine: StatusLineState = { type: "notInstalled" };
  const noop = () => undefined;

  return {
    async init() {
      const response = await fetch("/api/init");
      state = (await response.json()) as InitialState;
      settings = {
        ...state.settings,
        theme: (params.get("theme") as Settings["theme"]) ?? state.settings.theme,
        appearance: (params.get("mode") as Settings["appearance"]) ?? state.settings.appearance,
        hideContent: params.get("hide") === "1",
      };
      statusLine = state.statusLine;
      return { ...state, settings, isPopup: params.get("popup") === "1" };
    },
    onDelta: noop,
    onPlanUsage: noop,
    onReceiver: noop,
    onSettings: noop,
    onNavigate: noop,
    async rescan() {},
    async fullRescan() {},
    async updateSettings(patch) {
      settings = { ...settings!, ...patch };
      return settings;
    },
    async setDirectories(directories) {
      return directories ?? state?.directories ?? [];
    },
    async pickFolder() {
      return undefined;
    },
    async setPricing(table: PricingTable | null) {
      return table ?? defaultPricing();
    },
    async statusLineState() {
      return statusLine;
    },
    async installStatusLine() {
      statusLine = { type: "installed" };
      return { state: statusLine };
    },
    async uninstallStatusLine() {
      statusLine = { type: "notInstalled" };
      return { state: statusLine };
    },
    async importDialog() {
      return 0;
    },
    async importPaths() {
      return 0;
    },
    pathForFile(file: File) {
      return file.name;
    },
    async regenerateToken() {
      return "xray_" + Math.random().toString(16).slice(2).padEnd(64, "0");
    },
    async savePDF() {
      window.print();
      return undefined;
    },
    async saveText(name: string, text: string) {
      const url = URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
      const link = Object.assign(document.createElement("a"), { href: url, download: name });
      link.click();
      URL.revokeObjectURL(url);
      return name;
    },
    async copyText(text: string) {
      await navigator.clipboard?.writeText(text).catch(noop);
    },
    async openPath() {},
    async openExternal(url: string) {
      window.open(url, "_blank");
    },
    async openMain() {},
    setTrayTitle: noop,
    async quit() {},
  };
}
