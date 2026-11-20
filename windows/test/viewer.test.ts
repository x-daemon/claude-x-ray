// The iPad's read-only API of the receiver: tokens, listing, file chunks, compression, limits.
import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { after, before, test } from "node:test";
import { inflateRawSync } from "node:zlib";
import { catalogRoots, idComponents, safeComponent, shortHash, TranscriptCatalog } from "../src/core/catalog";
import { normalizeServer, tailscaleAddress, viewerLink } from "../src/core/viewerLink";

const base = mkdtempSync(path.join(os.tmpdir(), "xray-viewer-"));
process.env.XRAY_SUPPORT_DIR = path.join(base, "support");
const projects = path.join(base, "projects");
const cloud = path.join(base, "support", "cloud");
const imported = path.join(base, "support", "imported");

function write(relative: string, text: string, modified: number): string {
  const file = path.join(base, relative);
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, text);
  utimesSync(file, modified, modified);
  return file;
}

const big = Array.from({ length: 2000 }, (_, i) => JSON.stringify({ n: i, text: "lorem ipsum ".repeat(5) })).join("\n") + "\n";
write("projects/-Users-me-app/s1.jsonl", '{"a":1}\n', 1_000);
write("projects/-Users-me-app/s1/subagents/agent-1.jsonl", big, 3_000);
write("projects/.hidden/x.jsonl", "{}\n", 4_000);
write("projects/-Users-me-app/notes.txt", "no", 4_000);
write("support/cloud/-home-user-demo/c1.jsonl", "{}\n{}\n", 2_000);
write("support/imported/sessions/my session (1).jsonl", "{}\n", 500);

after(() => rmSync(base, { recursive: true, force: true }));

test("catalog: safe ids, newest first, only listed files resolve", async () => {
  const roots = catalogRoots([projects, projects, cloud, imported], cloud, imported);
  assert.equal(roots.length, 3);
  assert.match(roots[0].key, /^local-[0-9a-f]{8}$/);
  assert.deepEqual(roots.slice(1).map((r) => r.key), ["cloud", "imported"]);
  const catalog = await TranscriptCatalog.build(roots);
  const local = roots[0].key;
  assert.deepEqual(catalog.files.map((f) => f.id), [
    `${local}/-Users-me-app/s1/subagents/agent-1.jsonl`,
    "cloud/-home-user-demo/c1.jsonl",
    `${local}/-Users-me-app/s1.jsonl`,
    "imported/sessions/my_session__1_.jsonl",
  ]);
  assert.equal(catalog.files[0].modified, 3_000);
  assert.equal(catalog.since(2_000).length, 2);
  assert.ok(catalog.pathFor("cloud/-home-user-demo/c1.jsonl")?.endsWith("c1.jsonl"));
  assert.equal(catalog.pathFor("cloud/../projects/-Users-me-app/s1.jsonl"), undefined);
  for (const f of catalog.files) assert.ok(idComponents(f.id), f.id);
});

test("ids and hashes match the macOS app", () => {
  assert.equal(shortHash("/Users/me/.claude/projects"), "8fe8b8e1");
  assert.equal(safeComponent("Проект 1.jsonl"), "_______1.jsonl");
  assert.equal(safeComponent(".."), "_");
  assert.equal(safeComponent("a".repeat(300) + ".jsonl").length, 116);
  assert.equal(idComponents("cloud/../a.jsonl"), undefined);
  assert.equal(idComponents("a.jsonl"), undefined);
  assert.equal(idComponents("cloud/a b.jsonl"), undefined);
});

test("connect link and addresses", () => {
  const link = viewerLink("My-PC.tailnet.ts.net/path?x=1", "xrayv_0123456789abcdef", "XDAEMON-PC");
  assert.equal(link, "s2a-xray://connect?server=https%3A%2F%2Fmy-pc.tailnet.ts.net&token=xrayv_0123456789abcdef&name=XDAEMON-PC");
  assert.equal(viewerLink("https://a.b", "short"), undefined);
  assert.equal(normalizeServer(" http://127.0.0.1:47318/ "), "http://127.0.0.1:47318");
  assert.equal(normalizeServer("file:///etc"), undefined);
  assert.equal(normalizeServer("https://user:pw@a.b"), undefined);
  assert.equal(tailscaleAddress('{"Self":{"DNSName":"XDaemon-PC.tailcd66fc.ts.net."}}'), "https://xdaemon-pc.tailcd66fc.ts.net");
  assert.equal(tailscaleAddress("nope"), undefined);
});

// MARK: The receiver over HTTP

let receiver: import("../src/main/receiver").TranscriptReceiver;
let port = 0;
const viewer = "xrayv_" + "a".repeat(64);
const upload = "xray_" + "b".repeat(64);
let config: import("../src/main/receiver").ReceiverConfig;

before(async () => {
  const { TranscriptReceiver } = await import("../src/main/receiver");
  port = 40_000 + Math.floor(Math.random() * 20_000);
  config = {
    port, acceptsUploads: true, uploadToken: upload, servesViewer: true, viewerToken: viewer,
    roots: () => catalogRoots([projects, cloud, imported], cloud, imported), name: "test-pc", version: "0.9.0",
  };
  await new Promise<void>((resolve) => {
    receiver = new TranscriptReceiver((status) => { if (status.listening) resolve(); });
    receiver.update(config);
  });
});

after(() => receiver?.stop(false));

const get = (route: string, token = viewer) =>
  fetch(`http://127.0.0.1:${port}${route}`, { headers: token ? { Authorization: `Bearer ${token}` } : {} });

test("the iPad API needs the viewer token, not the upload token", async () => {
  assert.equal((await get("/v1/info", "")).status, 401);
  assert.equal((await get("/v1/info", upload)).status, 401);
  const info = await (await get("/v1/info")).json() as { name: string; files: number; platform: string; version: string };
  assert.equal(info.name, "test-pc");
  assert.equal(info.files, 4);
  assert.equal(info.version, "0.9.0");
  const posted = await fetch(`http://127.0.0.1:${port}/v1/transcript`, {
    method: "POST", headers: { Authorization: `Bearer ${viewer}`, "X-Path": "-p/x.jsonl" }, body: "{}\n",
  });
  assert.equal(posted.status, 401, "the viewer token cannot upload");
  assert.ok(receiver.status.viewerRejected >= 2);
});

test("files: listing, chunks, compression, offsets beyond the end, unknown ids", async () => {
  const listing = await (await get("/v1/files")).json() as { files: { id: string; size: number }[]; now: number };
  assert.equal(listing.files.length, 4);
  assert.ok(listing.now > 1_700_000_000);
  const recent = await (await get("/v1/files?since=2000")).json() as { files: unknown[] };
  assert.equal(recent.files.length, 2);

  const agent = listing.files[0];
  const plain = await get(`/v1/file?id=${encodeURIComponent(agent.id)}&from=10&max=1024`);
  assert.equal(plain.status, 200);
  assert.equal(plain.headers.get("x-file-size"), String(Buffer.byteLength(big)));
  assert.equal(plain.headers.get("x-from"), "10");
  assert.equal(Buffer.from(await plain.arrayBuffer()).toString(), big.slice(10, 10 + 1024));

  const packed = await get(`/v1/file?id=${encodeURIComponent(agent.id)}&from=0&z=1`);
  assert.equal(packed.headers.get("x-encoding"), "deflate-raw");
  const body = Buffer.from(await packed.arrayBuffer());
  assert.ok(body.length < Buffer.byteLength(big) / 4, "compressed");
  assert.equal(inflateRawSync(body).toString(), big);
  assert.equal(packed.headers.get("x-length"), String(Buffer.byteLength(big)));

  const end = await get(`/v1/file?id=${encodeURIComponent(agent.id)}&from=99999999`);
  assert.equal(end.status, 200);
  assert.equal((await end.arrayBuffer()).byteLength, 0);
  assert.equal((await get("/v1/file?id=cloud%2F..%2F..%2Fetc%2Fpasswd")).status, 404);
  assert.equal((await get("/v1/file")).status, 400);
  assert.equal((await get("/v1/plan-usage")).status, 204);
});

test("iPad access off: 403, and the upload still works", async () => {
  receiver.update({ ...config, servesViewer: false });
  assert.equal((await get("/v1/files")).status, 403);
  const posted = await fetch(`http://127.0.0.1:${port}/v1/transcript`, {
    method: "POST", headers: { Authorization: `Bearer ${upload}`, "X-Path": "-home-user-demo/new.jsonl" }, body: '{"x":1}\n',
  });
  assert.equal(posted.status, 200);
  receiver.update(config);
  const listing = await (await get("/v1/files")).json() as { files: { id: string }[] };
  assert.ok(listing.files.some((f) => f.id === "cloud/-home-user-demo/new.jsonl"), "an upload shows up in the listing");
});
