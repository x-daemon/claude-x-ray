// Synthetic transcript lines shaped like Claude Code's JSONL (port of Tests/XRayCoreTests/Fixtures.swift).
process.env.TZ = "UTC";

import { randomUUID } from "node:crypto";
import { parseActivityLine } from "../src/core/activityParser";
import type { ActivityItem } from "../src/core/activity";
import { defaultPricing, priceEvents, type PricedEvent } from "../src/core/pricing";
import { parseUsageLine, UsageStore } from "../src/core/transcript";

/** UTC epoch ms from components. */
export const date = (y: number, mo: number, d: number, h: number, mi = 0, s = 0): number => Date.UTC(y, mo - 1, d, h, mi, s);
export const iso = (ms: number): string => new Date(ms).toISOString();

export interface AssistantOptions {
  id?: string;
  requestId?: string | null;
  timestamp?: number;
  model?: string;
  input?: number;
  output?: number;
  cacheRead?: number;
  write5m?: number;
  write1h?: number;
  thinking?: number;
  session?: string;
  cwd?: string;
  branch?: string | null;
  sidechain?: boolean;
  effort?: unknown;
  speed?: string;
  webSearches?: number;
  contentType?: string;
}

export function assistantLine(o: AssistantOptions = {}): string {
  const write5m = o.write5m ?? 0;
  const write1h = o.write1h ?? 20_000;
  const entry: Record<string, unknown> = {
    type: "assistant",
    uuid: randomUUID(),
    timestamp: iso(o.timestamp ?? date(2026, 11, 14, 17, 23)),
    sessionId: o.session ?? "session-a",
    cwd: o.cwd ?? "/Users/me/code/app",
    isSidechain: o.sidechain ?? false,
    version: "2.1.325",
    message: {
      id: o.id ?? "msg_01",
      type: "message",
      role: "assistant",
      model: o.model ?? "claude-opus-5-5",
      content: [{ type: o.contentType ?? "text" }],
      stop_reason: null,
      usage: {
        input_tokens: o.input ?? 2,
        output_tokens: o.output ?? 400,
        cache_read_input_tokens: o.cacheRead ?? 60_000,
        cache_creation_input_tokens: write5m + write1h,
        cache_creation: { ephemeral_5m_input_tokens: write5m, ephemeral_1h_input_tokens: write1h },
        output_tokens_details: { thinking_tokens: o.thinking ?? 200 },
        server_tool_use: { web_search_requests: o.webSearches ?? 0, web_fetch_requests: 0 },
        service_tier: "standard",
        speed: o.speed ?? "standard",
        fallback_credit: null,
        inference_geo: "global",
      },
    },
  };
  const requestId = o.requestId === undefined ? "req_01" : o.requestId;
  if (requestId !== null) entry.requestId = requestId;
  const branch = o.branch === undefined ? "main" : o.branch;
  if (branch !== null) entry.gitBranch = branch;
  const effort = o.effort === undefined ? "xhigh" : o.effort;
  if (effort !== null) entry.effort = effort;
  return JSON.stringify(entry);
}

export function userLine(text = "Привет", session = "session-a"): string {
  return JSON.stringify({ type: "user", timestamp: iso(date(2026, 11, 14, 17, 20)), sessionId: session, message: { role: "user", content: text } });
}

export function priced(lines: string[], pricing = defaultPricing()): PricedEvent[] {
  const store = new UsageStore(lines.map((l) => parseUsageLine(l)).filter((e) => e !== undefined));
  return priceEvents(pricing, store.events);
}

// MARK: Activity lines

export const t0 = date(2026, 11, 14, 17, 0);
export const at = (seconds: number): number => t0 + seconds * 1000;

const base = (type: string, seconds: number, uuid: string, sidechain = false): Record<string, unknown> => ({
  type, uuid, timestamp: iso(at(seconds)), sessionId: "s1", cwd: "/Users/me/code/app", gitBranch: "main", isSidechain: sidechain,
});

export const Act = {
  base,
  json: (o: unknown): string => JSON.stringify(o),
  prompt(text: string, seconds: number, uuid: string = randomUUID(), meta = false): string {
    const entry = base("user", seconds, uuid);
    entry.message = { role: "user", content: text };
    if (meta) entry.isMeta = true;
    return JSON.stringify(entry);
  },
  userBlocks(blocks: unknown[], seconds: number, uuid: string = randomUUID(), extra: Record<string, unknown> = {}, sidechain = false): string {
    const entry = { ...base("user", seconds, uuid, sidechain), message: { role: "user", content: blocks }, ...extra };
    return JSON.stringify(entry);
  },
  assistant(block: unknown, seconds: number, msg: string, opts: { stop?: string | null; extra?: Record<string, unknown>; sidechain?: boolean; model?: string } = {}): string {
    const stop = opts.stop === undefined ? "tool_use" : opts.stop;
    const entry = {
      ...base("assistant", seconds, randomUUID(), opts.sidechain ?? false),
      message: { id: msg, model: opts.model ?? "claude-opus-5-5", role: "assistant", content: [block], stop_reason: stop },
      requestId: "req_" + msg,
      perTurnEffort: "xhigh",
      requestedModel: "claude-opus-5-5",
      ...(opts.extra ?? {}),
    };
    return JSON.stringify(entry);
  },
  thinking(seconds: number, msg: string, ms: number): string {
    return Act.assistant({ type: "thinking", thinking: "", signature: "sig" }, seconds, msg, { extra: { thinkingDurationMs: ms } });
  },
  toolUse(id: string, name: string, input: Record<string, unknown>, seconds: number, msg: string, streamMs?: number, sidechain = false): string {
    return Act.assistant({ type: "tool_use", id, name, input }, seconds, msg, { extra: streamMs !== undefined ? { toolInputStreamMs: streamMs } : {}, sidechain });
  },
  toolResult(id: string, content: unknown, seconds: number, isError = false, result?: Record<string, unknown>): string {
    const extra: Record<string, unknown> = { permissionDecision: { decision: "accept", source: "config", reasonType: "rule", ruleSource: "cliArg" } };
    if (result) extra.toolUseResult = result;
    const block: Record<string, unknown> = { type: "tool_result", tool_use_id: id, content };
    if (isError) block.is_error = true;
    return Act.userBlocks([block], seconds, randomUUID(), extra);
  },
  reply(text: string, seconds: number, msg: string, stop: string | null = "end_turn"): string {
    return Act.assistant({ type: "text", text }, seconds, msg, { stop });
  },
  attachment(payload: Record<string, unknown>, seconds: number): string {
    return JSON.stringify({ ...base("attachment", seconds, randomUUID()), attachment: payload });
  },
  items(lines: string[]): ActivityItem[] {
    return lines.flatMap((l) => parseActivityLine(l));
  },
};
