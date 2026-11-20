// The transcripts X-Ray offers to its iPad app, listed with path-safe ids and found again by id
// (Node only). Port of XRayCore/Sync/TranscriptCatalog.swift.
import { promises as fs } from "node:fs";
import * as path from "node:path";

export interface CatalogFile {
  /** "<root>/<folders>/<file>.jsonl": letters, digits, ".", "_" and "-" between the slashes. */
  id: string;
  size: number;
  /** Last change, seconds since 1970. */
  modified: number;
}

export interface CatalogRoot {
  key: string;
  dir: string;
}

/** FNV-1a (64 bit) of the text, folded to 32 bits, as 8 hex digits: same as the macOS app. */
export function shortHash(text: string): string {
  let hash = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(text, "utf8")) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return Number((hash ^ (hash >> 32n)) & 0xffffffffn).toString(16).padStart(8, "0");
}

/** A file or folder name as an id holds it: other characters become "_", at most 120 of them. */
export function safeComponent(name: string): string {
  let result = "";
  for (const ch of name) result += /^[A-Za-z0-9._-]$/.test(ch) ? ch : "_";
  if (result.length > 120) {
    const ext = path.posix.extname(result).slice(1);
    result = result.slice(0, 110) + (ext ? "." + ext : "");
  }
  return !result || result === "." || result === ".." ? "_" : result;
}

/** The parts of an id X-Ray would hand out; undefined for anything else. */
export function idComponents(id: string): string[] | undefined {
  const parts = id.split("/");
  if (parts.length < 2 || parts.length > 12 || !id.endsWith(".jsonl")) return undefined;
  return parts.every((p) => p.length > 0 && p.length <= 128 && safeComponent(p) === p) ? parts : undefined;
}

/** "cloud" and "imported" for X-Ray's own folders, "local-<hash of the path>" for the others. */
export function catalogRoots(directories: string[], cloud: string, imported: string): CatalogRoot[] {
  const result: CatalogRoot[] = [];
  const seen = new Set<string>();
  const same = (a: string, b: string) => path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase();
  for (const dir of directories) {
    const resolved = path.resolve(dir);
    if (seen.has(resolved.toLowerCase())) continue;
    seen.add(resolved.toLowerCase());
    const key = same(dir, cloud) ? "cloud" : same(dir, imported) ? "imported" : "local-" + shortHash(resolved);
    result.push({ key, dir });
  }
  return result;
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

/** A listing of the scan folders. An id only ever reaches a file this listing found. */
export class TranscriptCatalog {
  private constructor(readonly files: CatalogFile[], private readonly paths: Map<string, string>) {}

  static async build(roots: CatalogRoot[]): Promise<TranscriptCatalog> {
    const files: CatalogFile[] = [];
    const paths = new Map<string, string>();
    for (const root of roots) {
      for await (const file of walk(root.dir)) {
        let stat;
        try {
          stat = await fs.stat(file);
        } catch {
          continue;
        }
        const relative = path.relative(root.dir, file).split(path.sep);
        let id = [root.key, ...relative.map(safeComponent)].join("/");
        if (paths.has(id)) {
          // Two names that differ only in characters an id cannot hold.
          const stem = id.slice(0, -".jsonl".length);
          let n = 2;
          while (paths.has(`${stem}_${n}.jsonl`)) n++;
          id = `${stem}_${n}.jsonl`;
        }
        paths.set(id, file);
        files.push({ id, size: stat.size, modified: stat.mtimeMs / 1000 });
      }
    }
    files.sort((a, b) => (a.modified === b.modified ? (a.id < b.id ? -1 : 1) : b.modified - a.modified));
    return new TranscriptCatalog(files, paths);
  }

  pathFor(id: string): string | undefined {
    return this.paths.get(id);
  }

  since(seconds?: number): CatalogFile[] {
    return seconds === undefined ? this.files : this.files.filter((f) => f.modified >= seconds);
  }
}
