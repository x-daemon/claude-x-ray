// Scans transcripts, watches the folders and keeps the state every window starts from.
import AdmZip from "adm-zip";
import { copyFileSync, existsSync, mkdirSync, watch, type FSWatcher } from "node:fs";
import * as path from "node:path";
import type { ActivityItem } from "../core/activity";
import { defaultProjectDirectories, isDirectory, TranscriptIngestor, type ScanResult } from "../core/ingest";
import type { UsageEvent } from "../core/model";
import { ActivityStore } from "../core/trace";
import { UsageStore } from "../core/transcript";
import type { Delta, ScanInfo } from "../shared/api";
import { Paths } from "./store";

/** How far back the live trace reads transcripts. */
export const ACTIVITY_RETENTION = 3 * 86_400_000;

export class IngestService {
  private ingestor = new TranscriptIngestor();
  readonly usage = new UsageStore();
  readonly activity = new ActivityStore(ACTIVITY_RETENTION);
  private watchers: FSWatcher[] = [];
  private scanning = false;
  private queued = false;
  private queuedReset = false;
  private debounce?: NodeJS.Timeout;
  private timer?: NodeJS.Timeout;
  scan: ScanInfo = { scanning: false, filesSeen: 0, linesRead: 0, duration: 0, errors: [], sources: [] };

  constructor(private configured: string[] | undefined, private readonly broadcast: (delta: Delta) => void) {}

  /** Configured folders (or the defaults) plus X-Ray's own folders once they exist. */
  get directories(): string[] {
    return this.configured?.length ? this.configured : defaultProjectDirectories();
  }

  get scanDirectories(): string[] {
    const result = [...this.directories];
    for (const own of [Paths.imported, Paths.cloud]) {
      if (isDirectory(own) && !result.some((d) => path.resolve(d).toLowerCase() === path.resolve(own).toLowerCase())) result.push(own);
    }
    return result;
  }

  start(): void {
    this.restartWatching();
    void this.rescan();
    // Watchers cover live updates; a slow poll catches folders created later.
    this.timer = setInterval(() => {
      this.activity.prune();
      void this.rescan();
    }, 60_000);
  }

  stop(): void {
    clearInterval(this.timer);
    for (const w of this.watchers) w.close();
    this.watchers = [];
  }

  setDirectories(directories: string[] | undefined): void {
    this.configured = directories;
    this.restartWatching();
    void this.fullRescan();
  }

  restartWatching(): void {
    for (const w of this.watchers) w.close();
    this.watchers = [];
    for (const dir of this.scanDirectories) {
      if (!isDirectory(dir)) continue;
      try {
        this.watchers.push(watch(dir, { recursive: true }, (_event, file) => {
          if (file && !String(file).endsWith(".jsonl")) return;
          this.schedule();
        }));
      } catch {
        // Unsupported recursive watching: the periodic rescan still picks up changes.
      }
    }
  }

  private schedule(): void {
    clearTimeout(this.debounce);
    this.debounce = setTimeout(() => void this.rescan(), 400);
  }

  snapshot(): { events: UsageEvent[]; activities: ActivityItem[] } {
    return { events: this.usage.events, activities: this.activity.items };
  }

  async fullRescan(): Promise<void> {
    if (this.scanning) {
      this.queued = true;
      this.queuedReset = true;
      return;
    }
    this.ingestor.reset();
    this.usage.removeAll();
    this.activity.removeAll();
    await this.rescan(true);
  }

  /** Reads whatever was appended since the last scan and pushes the new events to the windows. */
  async rescan(reset = false): Promise<void> {
    if (this.scanning) {
      this.queued = true;
      return;
    }
    this.scanning = true;
    this.scan = { ...this.scan, scanning: true };
    let result: ScanResult | undefined;
    try {
      result = await this.ingestor.scan(this.scanDirectories, Date.now() - ACTIVITY_RETENTION);
    } catch (error) {
      this.scan = { ...this.scan, errors: [(error as Error).message] };
    }
    if (result) {
      const before = this.usage.count;
      this.usage.merge(result.events);
      const newActivities = result.activities.filter((a) => a.timestamp >= Date.now() - ACTIVITY_RETENTION);
      this.activity.merge(newActivities);
      this.scan = {
        scanning: false,
        lastScan: Date.now(),
        filesSeen: result.filesSeen,
        linesRead: result.linesRead,
        duration: result.duration,
        errors: result.errors.slice(0, 20),
        sources: result.sources,
      };
      // Events are sent whole (a later copy can replace an earlier one); the renderer de-duplicates.
      this.broadcast({ events: result.events, activities: newActivities, scan: this.scan, reset });
      void before;
    } else {
      this.scan = { ...this.scan, scanning: false, lastScan: Date.now() };
      this.broadcast({ events: [], activities: [], scan: this.scan, reset });
    }
    this.scanning = false;
    if (this.queued) {
      const again = this.queuedReset;
      this.queued = false;
      this.queuedReset = false;
      if (again) await this.fullRescan();
      else await this.rescan();
    }
  }

  /**
   * Copies transcripts (.jsonl, or .zip archives of them) into X-Ray's import folder, for example
   * logs of cloud sessions. Returns how many files were taken.
   */
  importFiles(files: string[]): number {
    const target = path.join(Paths.imported, "sessions");
    mkdirSync(target, { recursive: true });
    let imported = 0;
    for (const file of files) {
      try {
        if (file.toLowerCase().endsWith(".jsonl")) {
          copyFileSync(file, path.join(target, path.basename(file)));
          imported++;
        } else if (file.toLowerCase().endsWith(".zip")) {
          const zip = new AdmZip(file);
          for (const entry of zip.getEntries()) {
            if (entry.isDirectory || !entry.entryName.toLowerCase().endsWith(".jsonl")) continue;
            // Flatten paths so an archive cannot write outside the import folder.
            const name = path.basename(entry.entryName.replace(/\\/g, "/"));
            if (!name || name.startsWith(".")) continue;
            zip.extractEntryTo(entry, target, false, true, false, name);
            imported++;
          }
        }
      } catch {
        // skip unreadable files
      }
    }
    if (imported > 0) {
      this.restartWatching();
      void this.rescan();
    }
    return imported;
  }

  ensureCloudFolder(): void {
    if (!existsSync(Paths.cloud)) {
      mkdirSync(Paths.cloud, { recursive: true });
      this.restartWatching();
    }
  }
}
