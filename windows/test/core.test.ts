import { assistantLine, date, priced, userLine } from "./fixtures";
import assert from "node:assert/strict";
import { test } from "node:test";
import { Analytics, sessionProject, sessionSummaries, UsageSummary, Windows } from "../src/core/analytics";
import { csvField, dailyCSV, markdownReport, sessionsCSV } from "../src/core/export";
import { Fmt } from "../src/core/fmt";
import { analyzeInsights } from "../src/core/insights";
import { contextWindow, dedupeKey, displayModelName, isFastMode, modelFamily, normalizeModel, projectName, zeroTokens } from "../src/core/model";
import {
  constantTimeEquals, mergePlanUsage, planUsageFromStatusLine, statusLineSummary, uploadRelativePath, validUploadLines, windowFraction,
} from "../src/core/plan";
import { costAsModel, costOf, costTotal, defaultPricing, matchPrice, mergingMissingDefaults, modelPrice } from "../src/core/pricing";
import { parseUsageLine, UsageStore } from "../src/core/transcript";

const near = (a: number, b: number, eps = 1e-9) => assert.ok(Math.abs(a - b) <= eps, `${a} ≈ ${b}`);
const table = defaultPricing();

test("parses assistant usage", () => {
  const line = assistantLine({
    id: "msg_A", requestId: "req_A", input: 3, output: 795, cacheRead: 190_584, write5m: 10, write1h: 509, thinking: 333,
    session: "s1", cwd: "/Users/me/code/xray", branch: "feature/x", sidechain: true, effort: "xhigh", speed: "fast", webSearches: 2,
  });
  const e = parseUsageLine(line)!;
  assert.equal(e.messageID, "msg_A");
  assert.equal(e.requestID, "req_A");
  assert.equal(dedupeKey(e), "msg_A|req_A");
  assert.equal(e.sessionID, "s1");
  assert.equal(projectName(e.projectPath), "xray");
  assert.equal(e.gitBranch, "feature/x");
  assert.ok(e.isSidechain);
  assert.equal(e.effort, "xhigh");
  assert.ok(isFastMode(e));
  assert.equal(e.webSearchRequests, 2);
  assert.deepEqual(e.tokens, { input: 3, output: 795, cacheRead: 190_584, cacheWrite5m: 10, cacheWrite1h: 509, thinking: 333 });
  assert.equal(e.timestamp, date(2026, 11, 14, 17, 23));
});

test("skips lines without billed usage and tolerates odd fields", () => {
  assert.equal(parseUsageLine(userLine()), undefined);
  assert.equal(parseUsageLine("not json at all"), undefined);
  assert.equal(parseUsageLine('{"type":"assistant","usage":'), undefined);
  assert.equal(parseUsageLine(assistantLine({ model: "<synthetic>" })), undefined);
  assert.equal(parseUsageLine(assistantLine({ input: 0, output: 0, cacheRead: 0, write5m: 0, write1h: 0, thinking: 0 })), undefined);
  const odd = parseUsageLine(assistantLine({ effort: { level: "high" } }))!;
  assert.equal(odd.effort, undefined);
  assert.equal(odd.tokens.output, 400);
});

test("old format counts cache writes as 5 minutes; fallbacks for session and project", () => {
  const old = parseUsageLine('{"type":"assistant","timestamp":"2025-06-01T10:00:00Z","sessionId":"old","cwd":"/tmp/p","message":{"id":"msg_old","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}')!;
  assert.equal(old.tokens.cacheWrite5m, 40);
  assert.equal(old.tokens.cacheWrite1h, 0);
  assert.equal(dedupeKey(old), "msg_old");
  const fb = parseUsageLine('{"type":"assistant","timestamp":"2026-01-02T03:04:05.678Z","message":{"id":"msg_x","model":"claude-haiku-5-5","usage":{"input_tokens":1,"output_tokens":2}}}', "file-session", "-Users-me-proj")!;
  assert.equal(fb.sessionID, "file-session");
  assert.equal(fb.projectPath, "-Users-me-proj");
  assert.equal(projectName("C:\\Users\\me\\code\\app"), "app");
});

test("store de-duplicates, keeps the larger output and sorts", () => {
  const store = new UsageStore();
  store.merge([parseUsageLine(assistantLine({ id: "m1", output: 10 }))!, parseUsageLine(assistantLine({ id: "m1", output: 400 }))!]);
  assert.equal(store.count, 1);
  assert.equal(store.events[0].tokens.output, 400);
  assert.equal(store.merge([parseUsageLine(assistantLine({ id: "m1", output: 5 }))!]), 0);
  store.merge([parseUsageLine(assistantLine({ id: "early", timestamp: date(2026, 11, 1, 0) }))!]);
  assert.equal(store.events[0].messageID, "early");
});

test("pricing: prefixes, provider ids, family fallback, costs and what-if", () => {
  assert.equal(matchPrice(table, "claude-opus-5-5").price?.displayName, "Opus 5.5");
  assert.equal(matchPrice(table, "claude-opus-5").price?.displayName, "Opus 5");
  assert.equal(matchPrice(table, "claude-fable-5-1").price?.displayName, "Fable 5.1");
  assert.equal(normalizeModel("us.anthropic.claude-opus-4-8-v1:0"), "claude-opus-4-8");
  assert.equal(normalizeModel("claude-opus-4-5@20251101"), "claude-opus-4-5");
  assert.equal(normalizeModel("claude-opus-5-5[1m]"), "claude-opus-5-5");
  const fallback = matchPrice(table, "claude-sonnet-4-5-20250929");
  assert.ok(fallback.isEstimated);
  assert.equal(fallback.price?.modelPrefix, "claude-sonnet-5-5");
  assert.equal(matchPrice(table, "gpt-something").price, undefined);

  const event = {
    messageID: "m", timestamp: 0, model: "claude-opus-5-5", sessionID: "s", projectPath: "/p", isSidechain: false,
    tokens: { input: 1e6, output: 1e6, cacheRead: 1e6, cacheWrite5m: 1e6, cacheWrite1h: 1e6, thinking: 0 }, webSearchRequests: 1000, webFetchRequests: 0,
  };
  const cost = costOf(table, event, matchPrice(table, event.model).price);
  near(cost.input, 4);
  near(cost.output, 20);
  near(cost.cacheRead, 0.2);
  near(cost.cacheWrite, 13);
  near(cost.webSearch, 10);
  near(costTotal(costOf(table, { ...event, speed: "fast", tokens: { ...zeroTokens(), output: 1e6 }, webSearchRequests: 0 }, matchPrice(table, "claude-opus-5-5").price)), 40);
  const haiku = { ...event, model: "claude-haiku-5-5", tokens: { ...zeroTokens(), input: 200_000, output: 1e6 }, webSearchRequests: 0 };
  near(costTotal(costOf(table, haiku, matchPrice(table, haiku.model).price)), 0.2 * 0.5 + 2.5);

  const p = priced([assistantLine({ id: "a", input: 0, output: 1_000_000, cacheRead: 0, write5m: 0, write1h: 0, thinking: 0 })]);
  near(costTotal(p[0].cost), 20);
  near(costAsModel(table, p, "claude-sonnet-5-5")!, 10);
  assert.equal(costAsModel(table, p, "claude-nope"), undefined);

  const saved = mergingMissingDefaults({ ...table, models: [modelPrice({ modelPrefix: "claude-opus-5-5", displayName: "Opus 5.5", input: 99, output: 99, cacheRead: 9 })] });
  assert.equal(saved.models.find((m) => m.modelPrefix === "claude-opus-5-5")?.input, 99);
  assert.equal(saved.models.length, table.models.length);
});

test("model names, families and context windows", () => {
  assert.equal(displayModelName("claude-opus-5-5"), "Opus 5.5");
  assert.equal(displayModelName("claude-sonnet-4-5-20250929"), "Sonnet 4.5");
  assert.equal(displayModelName("claude-3-5-sonnet-20241022"), "Sonnet 3.5");
  assert.equal(modelFamily("claude-mythos-5-2"), "mythos");
  assert.equal(modelFamily("whatever"), "other");
  assert.equal(contextWindow("claude-opus-5-5"), 1_000_000);
  assert.equal(contextWindow("claude-haiku-4-5"), 200_000);
  assert.equal(contextWindow("claude-sonnet-4-5-20250929[1m]"), 1_000_000);
});

test("analytics: groups, buckets, heatmap, burn rate, sessions", () => {
  const events = priced([
    assistantLine({ id: "a", model: "claude-opus-5-5" }),
    assistantLine({ id: "b", model: "claude-opus-5-5" }),
    assistantLine({ id: "c", model: "claude-haiku-5-5" }),
  ]);
  const groups = Analytics.group(events, (e) => e.model);
  assert.deepEqual(groups.map((g) => g.key), ["claude-opus-5-5", "claude-haiku-5-5"]);
  near(groups.reduce((s, g) => s + g.summary.totalCost, 0), UsageSummary.of(events).totalCost);

  const daily = priced([assistantLine({ id: "a", timestamp: date(2026, 11, 10, 9) }), assistantLine({ id: "b", timestamp: date(2026, 11, 12, 23, 59) })]);
  const buckets = Analytics.buckets(daily, "day", { start: date(2026, 11, 10, 0), end: date(2026, 11, 13, 0) }, (e) => e.model);
  assert.deepEqual(buckets.map((b) => b.summary.requests), [1, 0, 1]);
  assert.equal(buckets[2].bySeries.get("claude-opus-5-5")?.requests, 1);

  const start = date(2026, 11, 14, 12);
  const live = priced([assistantLine({ id: "a", timestamp: start + 60_000 }), assistantLine({ id: "b", timestamp: start + 240_000 }), assistantLine({ id: "c", timestamp: start + 660_000 })]);
  assert.deepEqual(Analytics.fixedBuckets(live, { start, end: start + 900_000 }, 300_000).map((b) => b.summary.requests), [2, 0, 1]);

  const cells = Analytics.heatmap(priced([assistantLine({ id: "mon", timestamp: date(2026, 11, 16, 9) }), assistantLine({ id: "sun", timestamp: date(2026, 11, 15, 22) })]));
  assert.equal(cells.length, 168);
  assert.equal(cells.find((c) => c.weekday === 0 && c.hour === 9)?.requests, 1);
  assert.equal(cells.find((c) => c.weekday === 6 && c.hour === 22)?.requests, 1);

  const now = date(2026, 11, 14, 12);
  const burn = Analytics.burnRate(priced([
    assistantLine({ id: "old", timestamp: now - 7_200_000, input: 0, output: 1e6, cacheRead: 0, write5m: 0, write1h: 0, thinking: 0 }),
    assistantLine({ id: "new", timestamp: now - 600_000, input: 0, output: 1e6, cacheRead: 0, write5m: 0, write1h: 0, thinking: 0 }),
  ]), now);
  assert.equal(burn.requests, 1);
  near(burn.costPerHour, 20);

  const sessions = sessionSummaries(priced([
    assistantLine({ id: "a", model: "claude-opus-5-5", cacheRead: 100_000, session: "s1" }),
    assistantLine({ id: "b", model: "claude-haiku-5-5", cacheRead: 10_000, session: "s1", sidechain: true }),
    assistantLine({ id: "c", session: "s2" }),
  ]));
  const s1 = sessions.find((s) => s.id === "s1")!;
  assert.deepEqual(s1.models, ["claude-haiku-5-5", "claude-opus-5-5"]);
  assert.equal(s1.peakContextTokens, 2 + 100_000 + 20_000);
  assert.ok(s1.sidechainCost > 0);
  assert.equal(sessionProject(s1), "app");
});

test("5-hour windows: start at the hour, projection, peak", () => {
  const windows = Windows.compute(priced([
    assistantLine({ id: "a", timestamp: date(2026, 11, 14, 10, 15) }),
    assistantLine({ id: "b", timestamp: date(2026, 11, 14, 11, 0) }),
    assistantLine({ id: "c", timestamp: date(2026, 11, 14, 14, 59) }),
    assistantLine({ id: "d", timestamp: date(2026, 11, 14, 15, 10) }),
    assistantLine({ id: "e", timestamp: date(2026, 11, 15, 9, 30) }),
  ]));
  assert.equal(windows.length, 3);
  assert.equal(windows[0].start, date(2026, 11, 14, 10));
  assert.equal(windows[0].end, date(2026, 11, 14, 15));
  assert.equal(windows[0].summary.requests, 3);
  assert.equal(windows[2].start, date(2026, 11, 15, 9));

  const one = Windows.compute(priced([assistantLine({ id: "a", timestamp: date(2026, 11, 14, 10), input: 0, output: 1e6, cacheRead: 0, write5m: 0, write1h: 0, thinking: 0 })]));
  const now = date(2026, 11, 14, 11);
  const active = Windows.active(one, now)!;
  near(Windows.remaining(active, now), 4 * 3_600_000, 1);
  near(Windows.progress(active, now), 0.2);
  near(Windows.projectedCost(active, now), 100, 1e-6);
  assert.equal(Windows.active(one, date(2026, 11, 14, 16)), undefined);

  const peak = Windows.peak(Windows.compute(priced([
    assistantLine({ id: "small", timestamp: date(2026, 11, 13, 10), output: 100 }),
    assistantLine({ id: "big", timestamp: date(2026, 11, 14, 10), output: 900_000 }),
  ])), date(2026, 11, 14, 11));
  assert.equal(peak?.start, date(2026, 11, 13, 10));
});

test("insights: cache, rewarms, model mix", () => {
  const good = analyzeInsights(table, priced([0, 1, 2, 3, 4].map((i) => assistantLine({ id: `m${i}`, cacheRead: 500_000, write1h: 1_000 }))));
  assert.equal(good.find((i) => i.id === "cache.hit")?.severity, "good");
  const low = analyzeInsights(table, priced([0, 1, 2, 3, 4].map((i) => assistantLine({ id: `m${i}`, input: 50_000, cacheRead: 1_000, write1h: 50_000 }))));
  assert.equal(low.find((i) => i.id === "cache.hit")?.severity, "warning");
  assert.ok(low.find((i) => i.id === "cache.writes"));
  assert.equal(low[0].severity, "warning");

  const start = date(2026, 11, 14, 9);
  const rewarm = analyzeInsights(table, priced([0, 1, 2, 3].map((i) => assistantLine({ id: `r${i}`, timestamp: start + i * 7_200_000, cacheRead: 1_000, write5m: 0, write1h: 100_000, session: "s1" }))))
    .find((i) => i.id === "cache.rewarm")!;
  assert.equal(rewarm.metric, "3×");
  near(rewarm.potentialSavings ?? 0, 3 * 0.1 * (8 - 0.2), 1e-6);

  const opus = priced([0, 1, 2].map((i) => assistantLine({ id: `o${i}`, model: "claude-opus-5-5" })));
  const mix = analyzeInsights(table, opus).find((i) => i.id === "model.mix")!;
  assert.equal(mix.kind, "tradeoff");
  near(mix.potentialSavings ?? 0, UsageSummary.of(opus).totalCost - costAsModel(table, opus, "claude-sonnet-5-5")!);
  assert.deepEqual(analyzeInsights(table, []), []);
});

test("exports: CSV and Markdown", () => {
  const events = priced([
    assistantLine({ id: "a", timestamp: date(2026, 11, 13, 10) }),
    assistantLine({ id: "b", timestamp: date(2026, 11, 14, 10), model: "claude-haiku-5-5" }),
    assistantLine({ id: "c", timestamp: date(2026, 11, 14, 11) }),
  ]);
  const rows = dailyCSV(events).trim().split("\n");
  assert.equal(rows.length, 4);
  assert.ok(rows[1].startsWith("2026-11-13,claude-opus-5-5,1,"));
  assert.ok(rows[2].startsWith("2026-11-14,claude-haiku-5-5,1,"));
  assert.equal(csvField("a,b"), '"a,b"');
  assert.equal(csvField('say "hi"'), '"say ""hi"""');
  const md = markdownReport("Отчёт", "7 дней", events, analyzeInsights(table, events));
  for (const heading of ["# Отчёт", "## Итого", "## По моделям", "## По проектам", "## Самые дорогие сессии", "## Оптимизация"]) assert.ok(md.includes(heading), heading);
  assert.ok(md.includes("Opus 5.5"));
  const csv = sessionsCSV(sessionSummaries(priced([assistantLine({ id: "a", cwd: "/Users/me/my,project" })])));
  assert.ok(csv.includes('"/Users/me/my,project"'));
});

test("formatting", () => {
  assert.equal(Fmt.usd(0), "$0.00");
  assert.equal(Fmt.usd(0.004), "<$0.01");
  assert.equal(Fmt.usd(12.346), "$12.35");
  assert.equal(Fmt.usd(1234.4), "$1,234");
  assert.equal(Fmt.tokens(950), "950");
  assert.equal(Fmt.tokens(12_340), "12.3K");
  assert.equal(Fmt.tokens(4_560_000), "4.56M");
  assert.equal(Fmt.tokens(2_000_000), "2M");
  assert.equal(Fmt.percent(0.385), "39%");
  assert.equal(Fmt.percent(0.042), "4.2%");
  assert.equal(Fmt.duration(2 * 3600 + 5 * 60), "2 ч 05 мин");
  assert.equal(Fmt.duration(14 * 60), "14 мин");
  assert.equal(Fmt.dateTime(date(2026, 11, 14, 7, 3)), "14.11 07:03");
  assert.equal(Fmt.isoDay(date(2026, 1, 2, 3)), "2026-01-02");
  assert.equal(Fmt.shortDuration(0.85), "850 мс");
  assert.equal(Fmt.shortDuration(4.24), "4.2 с");
  assert.equal(Fmt.shortDuration(185), "3 мин 05 с");
  assert.equal(Fmt.ms(2128), "2.1 с");
  assert.equal(Fmt.bytes(820), "820 Б");
  assert.equal(Fmt.bytes(12_600), "12.3 КБ");
  assert.equal(Fmt.plural(3, "раз", "раза", "раз"), "3 раза");
  assert.equal(Fmt.plural(12, "раз", "раза", "раз"), "12 раз");
  assert.equal(Fmt.plural(21, "событие", "события", "событий"), "21 событие");
  assert.equal(Fmt.ago(42), "только что");
  assert.equal(Fmt.ago(12 * 60 + 30), "12 мин назад");
  assert.equal(Fmt.ago(4 * 86_400 + 3600), "4 дня назад");
  assert.equal(Fmt.span(3 * 86_400 + 4 * 3600 + 59), "3 дня 4 ч");
  assert.equal(Fmt.span(86_400 + 120), "1 день");
});

test("plan usage from the status line", () => {
  const documented = JSON.stringify({
    session_id: "abc123", model: { id: "claude-opus-5-5", display_name: "Opus 5.5" }, version: "2.1.325", context_window: { used_percentage: 41.6 },
    rate_limits: {
      five_hour: { used_percentage: 23.5, resets_at: 1738425600 },
      seven_day: { used_percentage: 41.2, resets_at: 1738857600 },
      spend_limit: { used_percentage: 62.8, resets_at: 1740787200, used_usd: 314.12, limit_usd: 500, period: "monthly" },
    },
  });
  const captured = 1_738_420_000_000;
  const usage = planUsageFromStatusLine(documented, captured)!;
  assert.deepEqual(usage.fiveHour, { usedPercentage: 23.5, resetsAt: 1_738_425_600_000 });
  assert.equal(usage.spendLimit?.usedUSD, 314.12);
  assert.equal(usage.model, "Opus 5.5");
  assert.equal(planUsageFromStatusLine('{"rate_limits":{}}'), undefined);
  assert.equal(planUsageFromStatusLine("nope"), undefined);
  const ms = planUsageFromStatusLine('{"model":"claude-sonnet-5-5","rate_limits":{"five_hour":{"used_percentage":"7","resets_at":1738425600000},"seven_day":{"used_percentage":12,"resets_at":"2025-02-06T16:00:00Z"}}}')!;
  assert.equal(ms.fiveHour?.resetsAt, 1_738_425_600_000);
  assert.equal(ms.sevenDay?.resetsAt, Date.UTC(2025, 1, 6, 16));
  assert.equal(ms.model, "Sonnet 5.5");
  assert.equal(statusLineSummary(documented, usage, captured), "Opus 5.5 · контекст 42% · 5 ч 24% · неделя 41%");
  assert.equal(statusLineSummary(documented, usage, 1_738_425_601_000), "Opus 5.5 · контекст 42% · неделя 41%");
  near(windowFraction({ usedPercentage: 87, resetsAt: 1000 }, 999), 0.87);
  assert.equal(windowFraction({ usedPercentage: 87, resetsAt: 1000 }, 1000), 0);

  const t = 1_000_000_000;
  const previous = { capturedAt: t, fiveHour: { usedPercentage: 30, resetsAt: t + 600_000 }, sevenDay: { usedPercentage: 10, resetsAt: t + 86_400_000 } };
  const later = mergePlanUsage({ capturedAt: t + 601_000, sevenDay: { usedPercentage: 11, resetsAt: t + 86_400_000 } }, previous);
  assert.equal(later.fiveHour, undefined);
  assert.equal(mergePlanUsage({ capturedAt: t + 60_000, fiveHour: { usedPercentage: 31, resetsAt: t + 600_000 } }, previous).sevenDay?.usedPercentage, 10);
});

test("uploads from cloud sessions", () => {
  const r = validUploadLines('{"type":"user"}\r\nnot json\n\n[1,2]\n{"type":"assistant","x":1}\n{"cut');
  assert.equal(r.data, '{"type":"user"}\n{"type":"assistant","x":1}\n');
  assert.equal(r.accepted, 2);
  assert.equal(r.rejected, 3);
  assert.equal(uploadRelativePath("-home-user/abc.jsonl", undefined, undefined), "-home-user/abc.jsonl");
  assert.equal(uploadRelativePath("-home-user/abc/subagents/agent-1.jsonl", "abc", undefined), "-home-user/abc/subagents/agent-1.jsonl");
  assert.equal(uploadRelativePath("../etc/passwd.jsonl", undefined, undefined), undefined);
  assert.equal(uploadRelativePath("-home-user/abc.txt", undefined, undefined), undefined);
  assert.equal(uploadRelativePath("a/b c/d.jsonl", undefined, undefined), undefined);
  assert.equal(uploadRelativePath(undefined, "s-1", "bad/../x"), "cloud/s-1.jsonl");
  assert.equal(uploadRelativePath(undefined, "../s", undefined), undefined);
  assert.ok(constantTimeEquals("Bearer abc", "Bearer abc"));
  assert.ok(!constantTimeEquals("Bearer abc", "Bearer abcd"));
});
