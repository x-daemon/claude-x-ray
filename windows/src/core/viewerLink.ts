// The link that connects X-Ray on the iPad to this computer (no Node APIs: the renderer builds it
// for the QR code). Port of XRayCore/Sync/ViewerLink.swift.

export const VIEWER_SCHEME = "s2a-xray";

/** "my-pc.tailnet.ts.net" → "https://my-pc.tailnet.ts.net"; http(s) only, no user, path or query. */
export function normalizeServer(text: string): string | undefined {
  const trimmed = text.trim();
  if (!trimmed) return undefined;
  let url: URL;
  try {
    url = new URL(trimmed.includes("://") ? trimmed : "https://" + trimmed);
  } catch {
    return undefined;
  }
  if ((url.protocol !== "https:" && url.protocol !== "http:") || !url.hostname || url.username || url.password) return undefined;
  return `${url.protocol}//${url.host.toLowerCase()}`;
}

/** s2a-xray://connect?server=…&token=…&name=…, which X-Ray on the iPad opens. */
export function viewerLink(server: string, token: string, name?: string): string | undefined {
  const normalized = normalizeServer(server);
  if (!normalized || !/^[A-Za-z0-9_-]{16,200}$/.test(token)) return undefined;
  const parts = [`server=${encodeURIComponent(normalized)}`, `token=${token}`];
  if (name?.trim()) parts.push(`name=${encodeURIComponent(name.trim().slice(0, 80))}`);
  return `${VIEWER_SCHEME}://connect?${parts.join("&")}`;
}

/** The computer's address from `tailscale status --json`: https://<machine>.<tailnet>.ts.net. */
export function tailscaleAddress(statusJSON: string): string | undefined {
  try {
    const name = String((JSON.parse(statusJSON) as { Self?: { DNSName?: string } }).Self?.DNSName ?? "").replace(/\.$/, "");
    return name && !name.includes("/") ? normalizeServer("https://" + name) : undefined;
  } catch {
    return undefined;
  }
}
