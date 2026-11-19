// App mark and the "S2A Claude X-Ray" header. Port of BrandMark and BrandHeader in Views/Theme.swift.
import * as I from "./icons";
import { L } from "../core/i18n";

export function BrandMark({ size = 32 }: { size?: number }) {
  return (
    <span class="brand-mark" style={{ width: `${size}px`, height: `${size}px`, borderRadius: `${size * 0.24}px` }} aria-hidden="true">
      <I.Activity size={size * 0.5} color="#fff" strokeWidth={2.6} />
    </span>
  );
}

export function BrandHeader() {
  return (
    <div class="brand-header">
      <BrandMark size={34} />
      <div class="stack-1 min0">
        <div class="headline ellipsis">S2A Claude X-Ray</div>
        <div class="caption secondary">{L`мониторинг Claude Code`}</div>
      </div>
    </div>
  );
}
