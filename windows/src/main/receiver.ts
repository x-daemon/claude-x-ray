// Receives transcript lines that cloud sessions push after every step (cloud/xray-push.py) and
// appends them under %APPDATA%\S2AClaudeXRay\cloud, which is scanned like ~/.claude/projects.
// It also serves the logs, read-only, to X-Ray on the iPad (GET /v1/...) with its own token, so a
// cloud session that holds the upload token cannot read anything back. Listens on 127.0.0.1 only;
// a tunnel such as Tailscale Funnel exposes it, and every request but /health must carry the
// matching token. Port of App/TranscriptReceiver.swift.
import { appendFileSync, existsSync, mkdirSync, promises as fs, readFileSync } from "node:fs";
import * as http from "node:http";
import * as path from "node:path";
import { deflateRawSync } from "node:zlib";
import { TranscriptCatalog, type CatalogRoot } from "../core/catalog";
import { constantTimeEquals, uploadRelativePath, validUploadLines } from "../core/plan";
import type { ReceiverStatus } from "../shared/api";
import { Paths } from "./store";
import { L } from "../core/i18n";

const MAX_BODY = 32 * 1024 * 1024;
/** The largest piece of a file one request returns. */
export const MAX_CHUNK = 16 * 1024 * 1024;

/** What the receiver accepts; the listener runs while either part is on. */
export interface ReceiverConfig {
  port: number;
  acceptsUploads: boolean;
  uploadToken: string;
  servesViewer: boolean;
  viewerToken: string;
  /** The folders the iPad may read: X-Ray's scan folders. */
  roots: () => CatalogRoot[];
  /** This computer's name and X-Ray's version, shown on the iPad. */
  name: string;
  version: string;
}

export class TranscriptReceiver {
  private server?: http.Server;
  private config?: ReceiverConfig;
  private catalog?: TranscriptCatalog;
  status: ReceiverStatus = { listening: false, port: 0, uploads: 0, lines: 0, rejectedAuth: 0, viewerRequests: 0, viewerRejected: 0 };

  constructor(private readonly onStatus: (status: ReceiverStatus) => void) {}

  /** Applies a configuration; the listener restarts only when the port changes or it was off. */
  update(config: ReceiverConfig): void {
    const previous = this.config;
    this.config = config;
    this.catalog = undefined;
    if (!config.acceptsUploads && !config.servesViewer) {
      this.stop();
      return;
    }
    if (!this.server || previous?.port !== config.port || this.status.error) this.listen(config.port);
  }

  private listen(port: number): void {
    this.stop(false);
    this.status = { ...this.status, port, error: undefined, listening: false };
    const server = http.createServer((req, res) => void this.handle(req, res));
    server.on("error", (error: NodeJS.ErrnoException) => {
      this.status = { ...this.status, listening: false, error: error.code === "EADDRINUSE" ? L`порт ${port} занят` : error.message };
      this.onStatus(this.status);
    });
    server.listen(port, "127.0.0.1", () => {
      this.status = { ...this.status, listening: true, error: undefined };
      this.onStatus(this.status);
    });
    this.server = server;
  }

  stop(publish = true): void {
    this.server?.close();
    this.server = undefined;
    if (publish) {
      this.status = { ...this.status, listening: false };
      this.onStatus(this.status);
    }
  }

  private respond(res: http.ServerResponse, code: number, body: unknown): void {
    const payload = JSON.stringify(body);
    res.writeHead(code, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload), "Cache-Control": "no-store", Connection: "close" });
    res.end(payload);
  }

  private async handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    const target = req.url ?? "/";
    const mark = target.indexOf("?");
    const url = mark < 0 ? target : target.slice(0, mark);
    const queryText = mark < 0 ? "" : target.slice(mark + 1);
    const config = this.config;
    if (req.method === "GET" && (url === "/" || url === "/health")) {
      this.respond(res, 200, { app: "S2A Claude X-Ray", receiver: "ok" });
      return;
    }
    if (req.method === "POST" && url === "/v1/transcript") {
      this.receiveUpload(req, res);
      return;
    }
    if (req.method === "GET" && ["/v1/info", "/v1/files", "/v1/file", "/v1/plan-usage"].includes(url)) {
      req.resume();
      if (!config?.servesViewer) {
        this.respond(res, 403, { error: "iPad access is off" });
        return;
      }
      if (!config.viewerToken || !constantTimeEquals(String(req.headers.authorization ?? ""), `Bearer ${config.viewerToken}`)) {
        this.status = { ...this.status, viewerRejected: this.status.viewerRejected + 1 };
        this.onStatus(this.status);
        this.respond(res, 401, { error: "unauthorized" });
        return;
      }
      this.status = { ...this.status, viewerRequests: this.status.viewerRequests + 1, lastViewerRequest: Date.now() };
      this.onStatus(this.status);
      try {
        await this.serveViewer(url, new URLSearchParams(queryText), config, res);
      } catch (error) {
        if (!res.headersSent) this.respond(res, 500, { error: (error as Error).message });
      }
      return;
    }
    req.resume();
    this.respond(res, 404, { error: "not found" });
  }

  private receiveUpload(req: http.IncomingMessage, res: http.ServerResponse): void {
    const config = this.config;
    if (!config?.acceptsUploads) {
      req.resume();
      this.respond(res, 403, { error: "cloud uploads are off" });
      return;
    }
    if (!config.uploadToken || !constantTimeEquals(String(req.headers.authorization ?? ""), `Bearer ${config.uploadToken}`)) {
      this.status = { ...this.status, rejectedAuth: this.status.rejectedAuth + 1 };
      this.onStatus(this.status);
      req.resume();
      this.respond(res, 401, { error: "unauthorized" });
      return;
    }
    const header = (name: string): string | undefined => {
      const v = req.headers[name];
      return Array.isArray(v) ? v[0] : v;
    };
    const relative = uploadRelativePath(header("x-path"), header("x-session-id"), header("x-project"));
    if (!relative) {
      req.resume();
      this.respond(res, 400, { error: "bad path" });
      return;
    }
    const chunks: Buffer[] = [];
    let size = 0;
    let aborted = false;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        aborted = true;
        this.respond(res, 413, { error: "too large" });
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (aborted) return;
      const lines = validUploadLines(Buffer.concat(chunks).toString("utf8"));
      try {
        if (lines.accepted > 0) {
          const target = path.join(Paths.cloud, ...relative.split("/"));
          mkdirSync(path.dirname(target), { recursive: true });
          appendFileSync(target, lines.data, "utf8");
          this.catalog = undefined;
        }
        this.status = {
          ...this.status,
          uploads: this.status.uploads + 1,
          lines: this.status.lines + lines.accepted,
          lastUpload: Date.now(),
          lastPath: relative,
        };
        this.onStatus(this.status);
        this.respond(res, 200, { accepted: lines.accepted, rejected: lines.rejected });
      } catch (error) {
        this.respond(res, 500, { error: (error as Error).message });
      }
    });
  }

  // MARK: iPad (read-only)

  private async freshCatalog(config: ReceiverConfig): Promise<TranscriptCatalog> {
    this.catalog = await TranscriptCatalog.build(config.roots());
    return this.catalog;
  }

  private async serveViewer(url: string, query: URLSearchParams, config: ReceiverConfig, res: http.ServerResponse): Promise<void> {
    if (url === "/v1/info") {
      const catalog = await this.freshCatalog(config);
      this.respond(res, 200, {
        app: "S2A Claude X-Ray",
        version: config.version,
        platform: process.platform === "win32" ? "Windows" : process.platform === "darwin" ? "macOS" : "Linux",
        name: config.name,
        files: catalog.files.length,
        bytes: catalog.files.reduce((sum, f) => sum + f.size, 0),
        newest: catalog.files[0]?.modified,
        planUsage: existsSync(Paths.planUsage),
      });
    } else if (url === "/v1/files") {
      const catalog = await this.freshCatalog(config);
      const since = query.has("since") ? Number(query.get("since")) : undefined;
      this.respond(res, 200, { files: catalog.since(Number.isFinite(since) ? since : undefined), now: Date.now() / 1000 });
    } else if (url === "/v1/file") {
      await this.serveFile(query, config, res);
    } else {
      let usage: string | undefined;
      try {
        usage = readFileSync(Paths.planUsage, "utf8");
        JSON.parse(usage);
      } catch {
        usage = undefined;
      }
      if (usage) {
        res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(usage), "Cache-Control": "no-store", Connection: "close" });
        res.end(usage);
      } else {
        res.writeHead(204, { "Cache-Control": "no-store", Connection: "close" });
        res.end();
      }
    }
  }

  /** ?id=<id>&from=<offset>&max=<bytes>&z=1: bytes of a listed transcript, raw deflate with z=1. */
  private async serveFile(query: URLSearchParams, config: ReceiverConfig, res: http.ServerResponse): Promise<void> {
    const id = query.get("id");
    if (!id) {
      this.respond(res, 400, { error: "id missing" });
      return;
    }
    const file = this.catalog?.pathFor(id) ?? (await this.freshCatalog(config)).pathFor(id);
    if (!file) {
      this.respond(res, 404, { error: "not found" });
      return;
    }
    let handle;
    try {
      handle = await fs.open(file, "r");
    } catch {
      this.respond(res, 404, { error: "not found" });
      return;
    }
    try {
      const size = (await handle.stat()).size;
      const from = Math.min(Math.max(0, Math.floor(Number(query.get("from") ?? 0)) || 0), size);
      const limit = Math.min(Math.max(Math.floor(Number(query.get("max") ?? "")) || 4 * 1024 * 1024, 1024), MAX_CHUNK);
      let chunk = Buffer.alloc(0);
      if (from < size) {
        const buffer = Buffer.alloc(Math.min(limit, size - from));
        const { bytesRead } = await handle.read(buffer, 0, buffer.length, from);
        chunk = buffer.subarray(0, bytesRead);
      }
      const headers: Record<string, string | number> = {
        "Content-Type": "application/octet-stream",
        "Cache-Control": "no-store",
        Connection: "close",
        "X-File-Size": size,
        "X-From": from,
        "X-Length": chunk.length,
      };
      if (query.get("z") === "1" && chunk.length > 512) {
        chunk = deflateRawSync(chunk);
        headers["X-Encoding"] = "deflate-raw";
      }
      headers["Content-Length"] = chunk.length;
      res.writeHead(200, headers);
      res.end(chunk);
    } finally {
      await handle.close();
    }
  }
}
