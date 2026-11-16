// Incremental transcript scanning (Node only). Port of XRayCore/Ingest/{IncrementalLineReader,
// TranscriptIngestor,ClaudeDataLocator}.swift.
import { promises as fs, statSync } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { type ActivityItem } from "./activity";
import { parseActivityLine } from "./activityParser";
import { type UsageEvent } from "./model";
import { parseUsageLine } from "./transcript";

/**
 * Reads a growing append-only file line by line, remembering where it stopped. A trailing line
 * without a newline is left for the next scan unless it is already complete JSON. Truncation or
 * replacement of the file (a different file id or a smaller size) restarts from the top.
 */
export class IncrementalLineReader {
  offset = 0;
  private fileID?: bigint;

  async readNewLines(file: string): Promise<string[]> {
    const stat = await fs.stat(file, { bigint: true });
    const size = Number(stat.size);
    const id = stat.ino;
    if ((this.fileID !== undefined && id !== this.fileID) || size < this.offset) this.offset = 0;
    this.fileID = id;
    if (size <= this.offset) return [];

    const handle = await fs.open(file, "r");
    let buffer: Buffer;
    try {
      buffer = Buffer.alloc(size - this.offset);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, this.offset);
      buffer = buffer.subarray(0, bytesRead);
    } finally {
      await handle.close();
    }
    if (!buffer.length) return [];

    const lines: string[] = [];
    let lineStart = 0;
    for (let i = 0; i < buffer.length; i++) {
      if (buffer[i] === 0x0a) {
        if (i > lineStart) lines.push(buffer.toString("utf8", lineStart, i).replace(/\r$/, ""));
        lineStart = i + 1;
      }
    }
    let consumed = lineStart;
    if (consumed < buffer.length) {
      const remainder = buffer.toString("utf8", consumed);
      try {
        JSON.parse(remainder);
        lines.push(remainder);
        consumed = buffer.length;
      } catch {
        // incomplete line: read it next time
      }
    }
    this.offset += consumed;
    return lines;
  }
}

/** What one scan found in one transcript folder. */
export interface SourceStat {
  directory: string;
  exists: boolean;
  /** Transcript files (*.jsonl) in the folder and its subfolders. */
  files: number;
  /** Epoch ms when the most recently written transcript was modified. */
  newestModification?: number;
}

export interface ScanResult {
  events: UsageEvent[];
  activities: ActivityItem[];
  filesSeen: number;
  filesRead: number;
  linesRead: number;
  errors: string[];
  /** Milliseconds. */
  duration: number;
  sources: SourceStat[];
}

export const newestModification = (r: ScanResult): number | undefined => {
  const dates = r.sources.map((s) => s.newestModification).filter((d): d is number => d !== undefined);
  return dates.length ? Math.max(...dates) : undefined;
};

export function isDirectory(dir: string): boolean {
  try {
    return statSync(dir).isDirectory();
  } catch {
    return false;
  }
}

async function* walk(dir: string): AsyncGenerator<string> {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (entry.name.startsWith(".")) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) yield full;
  }
}

/** Scans transcript folders incrementally, one reader per file. */
export class TranscriptIngestor {
  private readers = new Map<string, IncrementalLineReader>();

  /** Forgets all read positions; the next scan reads everything again. */
  reset(): void {
    this.readers.clear();
  }

  /** activitySince (epoch ms): transcripts modified after it are also parsed into activity items. */
  async scan(directories: string[], activitySince?: number): Promise<ScanResult> {
    const started = Date.now();
    const result: ScanResult = { events: [], activities: [], filesSeen: 0, filesRead: 0, linesRead: 0, errors: [], duration: 0, sources: [] };
    for (const directory of directories) {
      const source: SourceStat = { directory, exists: isDirectory(directory), files: 0 };
      result.sources.push(source);
      if (!source.exists) continue;
      for await (const file of walk(directory)) {
        result.filesSeen++;
        source.files++;
        let modified: number | undefined;
        try {
          modified = (await fs.stat(file)).mtimeMs;
        } catch {
          continue;
        }
        if (source.newestModification === undefined || modified > source.newestModification) source.newestModification = modified;

        const key = path.resolve(file);
        let reader = this.readers.get(key);
        if (!reader) this.readers.set(key, (reader = new IncrementalLineReader()));
        let lines: string[];
        try {
          lines = await reader.readNewLines(file);
        } catch (error) {
          result.errors.push(`${path.basename(file)}: ${(error as Error).message}`);
          continue;
        }
        if (!lines.length) continue;
        result.filesRead++;
        result.linesRead += lines.length;
        const sessionID = path.basename(file, ".jsonl");
        const project = path.basename(path.dirname(file));
        const wantsActivity = activitySince !== undefined && modified >= activitySince;
        for (const line of lines) {
          const event = parseUsageLine(line, sessionID, project);
          if (event) result.events.push(event);
          if (wantsActivity) result.activities.push(...parseActivityLine(line, sessionID, project));
        }
      }
    }
    result.duration = Date.now() - started;
    return result;
  }
}

/**
 * Candidate projects folders, in priority order: every entry of CLAUDE_CONFIG_DIR (comma
 * separated), then ~/.claude/projects and ~/.config/claude/projects (%USERPROFILE% on Windows).
 */
export function candidateProjectDirectories(env: NodeJS.ProcessEnv = process.env, home = os.homedir()): string[] {
  const result: string[] = [];
  for (const raw of (env.CLAUDE_CONFIG_DIR ?? "").split(",")) {
    const p = raw.trim();
    if (!p) continue;
    const expanded = p.startsWith("~") ? path.join(home, p.slice(1)) : p;
    result.push(path.join(expanded, "projects"));
  }
  result.push(path.join(home, ".claude", "projects"), path.join(home, ".config", "claude", "projects"));
  const seen = new Set<string>();
  return result.filter((p) => {
    const key = path.resolve(p).toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/** Candidates that exist; falls back to ~/.claude/projects so the UI can show where it looks. */
export function defaultProjectDirectories(env: NodeJS.ProcessEnv = process.env, home = os.homedir()): string[] {
  const candidates = candidateProjectDirectories(env, home);
  const existing = candidates.filter(isDirectory);
  return existing.length ? existing : [path.join(home, ".claude", "projects")];
}
