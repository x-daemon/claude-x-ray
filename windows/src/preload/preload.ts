// Exposes window.xray to the renderer; the renderer never touches Node or Electron directly.
import { contextBridge, ipcRenderer, webUtils } from "electron";
import { CHANNELS, type XRayBridge } from "../shared/api";

const on = (channel: string) => (callback: (...args: never[]) => void) => {
  ipcRenderer.on(channel, (_event, payload) => (callback as (p: unknown) => void)(payload));
};

const bridge: XRayBridge = {
  init: () => ipcRenderer.invoke(CHANNELS.init),
  onDelta: on(CHANNELS.delta) as XRayBridge["onDelta"],
  onPlanUsage: on(CHANNELS.planUsage) as XRayBridge["onPlanUsage"],
  onReceiver: on(CHANNELS.receiver) as XRayBridge["onReceiver"],
  onSettings: (callback) => ipcRenderer.on(CHANNELS.settings, (_e, p) => callback(p.settings, p.directories)),
  onNavigate: on(CHANNELS.navigate) as XRayBridge["onNavigate"],
  rescan: () => ipcRenderer.invoke(CHANNELS.rescan),
  fullRescan: () => ipcRenderer.invoke(CHANNELS.fullRescan),
  updateSettings: (patch) => ipcRenderer.invoke(CHANNELS.updateSettings, patch),
  setDirectories: (directories) => ipcRenderer.invoke(CHANNELS.setDirectories, directories),
  pickFolder: () => ipcRenderer.invoke(CHANNELS.pickFolder),
  setPricing: (table) => ipcRenderer.invoke(CHANNELS.setPricing, table),
  statusLineState: () => ipcRenderer.invoke(CHANNELS.statusLineState),
  installStatusLine: () => ipcRenderer.invoke(CHANNELS.installStatusLine),
  uninstallStatusLine: () => ipcRenderer.invoke(CHANNELS.uninstallStatusLine),
  importDialog: () => ipcRenderer.invoke(CHANNELS.importDialog),
  importPaths: (paths) => ipcRenderer.invoke(CHANNELS.importPaths, paths),
  pathForFile: (file) => webUtils.getPathForFile(file),
  regenerateToken: () => ipcRenderer.invoke(CHANNELS.regenerateToken),
  savePDF: (name, size) => ipcRenderer.invoke(CHANNELS.savePDF, name, size),
  saveText: (name, text, kind) => ipcRenderer.invoke(CHANNELS.saveText, name, text, kind),
  copyText: (text) => ipcRenderer.invoke(CHANNELS.copyText, text),
  openPath: (target) => ipcRenderer.invoke(CHANNELS.openPath, target),
  openExternal: (url) => ipcRenderer.invoke(CHANNELS.openExternal, url),
  openMain: (screen) => ipcRenderer.invoke(CHANNELS.openMain, screen),
  quit: () => ipcRenderer.invoke(CHANNELS.quit),
};

contextBridge.exposeInMainWorld("xray", bridge);
