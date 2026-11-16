// Shared building blocks: cards, stat tiles, bars, chips, segmented controls, legends.
// Port of Views/Components.swift and the small views of Views/Trace/TraceStyle.swift.
import type { ComponentChildren, CSSProperties } from "preact";
import type { LucideIcon } from "lucide-preact";
import { Fmt } from "../core/fmt";

export const cls = (...names: (string | false | undefined | null)[]): string => names.filter(Boolean).join(" ");

/** Inline Markdown subset used in help texts: **bold** and `code`. */
export function Md({ text }: { text: string }) {
  const parts = text.split(/(\*\*[^*]+\*\*|`[^`]+`)/g).filter(Boolean);
  return (
    <>
      {parts.map((part, i) =>
        part.startsWith("**") ? <strong key={i}>{part.slice(2, -2)}</strong>
          : part.startsWith("`") ? <code key={i}>{part.slice(1, -1)}</code>
            : part,
      )}
    </>
  );
}

export function Icon({ icon: I, size = 16, color, class: className }: { icon: LucideIcon; size?: number; color?: string; class?: string }) {
  return <I size={size} color={color ?? "currentColor"} strokeWidth={1.9} class={cls("icon", className)} aria-hidden="true" />;
}

/** Titled container for a chart or a block of details. */
export function Card(props: { title: string; subtitle?: string; children?: ComponentChildren; class?: string; style?: CSSProperties; actions?: ComponentChildren }) {
  return (
    <section class={cls("card", props.class)} style={props.style}>
      <header class="card-head">
        <h3>{props.title}</h3>
        <span class="spacer" />
        {props.subtitle ? <span class="caption secondary">{props.subtitle}</span> : null}
        {props.actions}
      </header>
      {props.children}
    </section>
  );
}

/** Headline number with a label and an optional caption. */
export function StatTile(props: { title: string; value: string; caption?: string; icon?: LucideIcon; tint?: string }) {
  return (
    <div class="tile">
      <div class="tile-title">
        {props.icon ? <Icon icon={props.icon} size={15} color={props.tint ?? "var(--accent)"} /> : null}
        <span>{props.title}</span>
      </div>
      <div class="tile-value num" title={props.value}>{props.value}</div>
      {props.caption ? <div class="caption secondary clamp2">{props.caption}</div> : null}
    </div>
  );
}

export function Tiles({ children }: { children: ComponentChildren }) {
  return <div class="tiles">{children}</div>;
}

/** Horizontal bar for a share of a limit. */
export function UsageBar({ fraction, color = "var(--accent)", height = 8 }: { fraction: number; color?: string; height?: number }) {
  const clamped = Math.min(Math.max(fraction || 0, 0), 1);
  return (
    <div class="usage-bar" style={{ height: `${height}px` }} role="meter" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(clamped * 100)} title={Fmt.percent(clamped)}>
      <div style={{ width: clamped > 0 ? `max(${height}px, ${clamped * 100}%)` : "0", background: color }} />
    </div>
  );
}

export interface RankedRow {
  id: string;
  label: string;
  detail?: string;
  value: number;
  valueText: string;
  color?: string;
  /** Stacked parts of the bar; undefined draws one solid bar. */
  segments?: { value: number; color: string }[];
  help?: string;
}

/** Labelled horizontal bars: label column, proportional bar, value. */
export function RankedBarList({ rows, labelWidth = 230 }: { rows: RankedRow[]; labelWidth?: number }) {
  const max = Math.max(...rows.map((r) => r.value), Number.MIN_VALUE);
  return (
    <div class="ranked" style={{ "--label-width": `${labelWidth}px` } as CSSProperties}>
      {rows.map((row) => {
        const width = Math.max(0, (row.value / max) * 100);
        return (
          <div class="ranked-row" key={row.id} title={row.help ?? `${row.label}: ${row.valueText}`}>
            <div class="ranked-label">
              <div class="ellipsis">{row.label}</div>
              {row.detail ? <div class="caption2 secondary ellipsis">{row.detail}</div> : null}
            </div>
            <div class="ranked-track">
              <div class="ranked-bar" style={{ width: `max(2px, ${width}%)` }}>
                {row.segments && row.value > 0
                  ? row.segments.map((s, i) => <span key={i} style={{ flexGrow: s.value, background: s.color }} />)
                  : <span style={{ flexGrow: 1, background: row.color ?? "var(--c-model)" }} />}
              </div>
            </div>
            <div class="ranked-value caption num secondary">{row.valueText}</div>
          </div>
        );
      })}
    </div>
  );
}

/** Small capsule label. */
export function Chip({ text, icon, tint = "var(--other)", title }: { text: string; icon?: LucideIcon; tint?: string; title?: string }) {
  return (
    <span class="chip" style={{ "--tint": tint } as CSSProperties} title={title}>
      {icon ? <Icon icon={icon} size={11} color={tint} /> : null}
      <span class="ellipsis">{text}</span>
    </span>
  );
}

export function Chips({ children, indent }: { children: ComponentChildren; indent?: number }) {
  return <div class="chips" style={indent ? { paddingLeft: `${indent}px` } : undefined}>{children}</div>;
}

/** Segmented control (a picker with .segmented style). */
export function Segmented<T extends string>(props: { value: T; options: { id: T; title: string }[]; onChange: (value: T) => void; class?: string; label?: string }) {
  return (
    <div class={cls("segmented", props.class)} role="tablist" aria-label={props.label}>
      {props.options.map((o) => (
        <button key={o.id} type="button" role="tab" aria-selected={o.id === props.value} class={o.id === props.value ? "on" : ""} onClick={() => props.onChange(o.id)}>
          {o.title}
        </button>
      ))}
    </div>
  );
}

export function Toggle({ checked, onChange, label, title }: { checked: boolean; onChange: (value: boolean) => void; label: string; title?: string }) {
  return (
    <label class="toggle" title={title}>
      <input type="checkbox" checked={checked} onChange={(e) => onChange((e.currentTarget as HTMLInputElement).checked)} />
      <span class="switch" aria-hidden="true" />
      <span>{label}</span>
    </label>
  );
}

export function Button(props: { children: ComponentChildren; onClick?: () => void; primary?: boolean; small?: boolean; disabled?: boolean; title?: string; icon?: LucideIcon; borderless?: boolean; class?: string }) {
  return (
    <button
      type="button"
      class={cls("btn", props.primary && "primary", props.small && "small", props.borderless && "borderless", props.class)}
      onClick={props.onClick}
      disabled={props.disabled}
      title={props.title}
    >
      {props.icon ? <Icon icon={props.icon} size={props.small ? 13 : 15} /> : null}
      {props.children}
    </button>
  );
}

/** Legend entries: colored swatch, text in the secondary text color. */
export function Legend({ items }: { items: { name: string; color: string; dashed?: boolean }[] }) {
  return (
    <div class="legend">
      {items.map((item) => (
        <span key={item.name} class="legend-item">
          <span class={cls("swatch", item.dashed && "dashed")} style={{ background: item.dashed ? undefined : item.color, borderColor: item.color }} />
          {item.name}
        </span>
      ))}
    </div>
  );
}

/** Monospaced, selectable block for prompts, commands and outputs. */
export function DetailBlock({ text }: { text: string }) {
  return <pre class="detail-block selectable">{text}</pre>;
}

/** Label with an icon in front (SwiftUI Label). */
export function Label({ icon, text, color, class: className, title }: { icon: LucideIcon; text: ComponentChildren; color?: string; class?: string; title?: string }) {
  return (
    <span class={cls("label", className)} style={color ? { color } : undefined} title={title}>
      <Icon icon={icon} size={13} />
      <span>{text}</span>
    </span>
  );
}

/** Key/value grid (SwiftUI Grid with two columns). */
export function KeyValues({ rows, align = "left" }: { rows: [string, ComponentChildren][]; align?: "left" | "right" }) {
  return (
    <div class={cls("kv", align === "right" && "kv-right")}>
      {rows.map(([k, v], i) => (
        <div class="kv-row" key={i}>
          <span class="secondary">{k}</span>
          <span class="num">{v}</span>
        </div>
      ))}
    </div>
  );
}

/** Table with a caption header row; cells are rendered as given. */
export function Table(props: { head: string[]; rows: ComponentChildren[][]; numeric?: number[]; class?: string; onRowClick?: (index: number) => void; selected?: number; keys?: string[] }) {
  const numeric = new Set(props.numeric ?? []);
  return (
    <div class={cls("table-wrap", props.class)}>
      <table class="table">
        <thead>
          <tr>{props.head.map((h, i) => <th key={i} class={numeric.has(i) ? "right" : ""}>{h}</th>)}</tr>
        </thead>
        <tbody>
          {props.rows.map((row, r) => (
            <tr
              key={props.keys?.[r] ?? r}
              class={cls(props.onRowClick && "clickable", props.selected === r && "selected")}
              onClick={props.onRowClick ? () => props.onRowClick!(r) : undefined}
            >
              {row.map((cell, i) => <td key={i} class={numeric.has(i) ? "right num" : ""}>{cell}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Empty({ text, height }: { text: string; height?: number }) {
  return <div class="empty-note secondary" style={height ? { minHeight: `${height}px` } : undefined}>{text}</div>;
}

/** Status message under a control: errors in the critical color, the rest secondary. */
export function Note({ text, error }: { text?: string; error?: boolean }) {
  if (!text) return null;
  return <div class={cls("caption", error ? "critical" : "secondary")}>{text}</div>;
}
