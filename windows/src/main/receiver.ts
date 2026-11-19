// Receives transcript lines that cloud sessions push after every step (cloud/xray-push.py) and
// appends them under %APPDATA%\S2AClaudeXRay\cloud, which is scanned like ~/.claude/projects.
// Listens on 127.0.0.1 only; a tunnel such as Tailscale Funnel exposes it, and every upload must
// carry the access token. Port of App/TranscriptReceiver.swift.
import { appendFileSync, mkdirSync } from "node:fs";
import * as http from "node:http";
import * as path from "node:path";
import { constantTimeEquals, uploadRelativePath, validUploadLines } from "../core/plan";
import type { ReceiverStatus } from "../shared/api";
import { Paths } from "./store";
import { L } from "../core/i18n";

const MAX_BODY = 32 * 1024 * 1024;

export class TranscriptReceiver {
  private server?: http.Server;
  private token = "";
  status: ReceiverStatus = { listening: false, port: 0, uploads: 0, lines: 0, rejectedAuth: 0 };

  constructor(private readonly onStatus: (status: ReceiverStatus) => void) {}

  start(port: number, token: string): void {
    this.stop(false);
    this.token = token;
    this.status = { ...this.status, port, error: undefined, listening: false };
    const server = http.createServer((req, res) => this.handle(req, res));
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
    res.writeHead(code, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload), Connection: "close" });
    res.end(payload);
  }

  private handle(req: http.IncomingMessage, res: http.ServerResponse): void {
    const url = (req.url ?? "/").split("?")[0];
    if (req.method === "GET" && (url === "/" || url === "/health")) {
      this.respond(res, 200, { app: "S2A Claude X-Ray", receiver: "ok" });
      return;
    }
    if (req.method !== "POST" || url !== "/v1/transcript") {
      this.respond(res, 404, { error: "not found" });
      return;
    }
    if (!this.token || !constantTimeEquals(String(req.headers.authorization ?? ""), `Bearer ${this.token}`)) {
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
}
