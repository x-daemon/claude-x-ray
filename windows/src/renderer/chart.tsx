// ECharts (SVG renderer) wrapper and the shared chart styling: recessive axes and hairline grid,
// thin bars with rounded data ends, 2 px lines, and a hover tooltip in the style of ChartTooltip.
import { BarChart, LineChart, ScatterChart, type BarSeriesOption, type LineSeriesOption, type ScatterSeriesOption } from "echarts/charts";
import {
  AxisPointerComponent, GridComponent, MarkLineComponent, TooltipComponent,
  type GridComponentOption, type MarkLineComponentOption, type TooltipComponentOption,
} from "echarts/components";
import * as echarts from "echarts/core";
import type { ComposeOption } from "echarts/core";
import { SVGRenderer } from "echarts/renderers";
import { useEffect, useRef } from "preact/hooks";
import { Fmt } from "../core/fmt";
import type { Palette } from "./theme";

echarts.use([BarChart, LineChart, ScatterChart, GridComponent, TooltipComponent, MarkLineComponent, AxisPointerComponent, SVGRenderer]);

export type ChartOption = ComposeOption<
  BarSeriesOption | LineSeriesOption | ScatterSeriesOption | GridComponentOption | TooltipComponentOption | MarkLineComponentOption
>;

export const FONT = `"Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, sans-serif`;
/** Bars never get thicker than this (px). */
export const BAR_MAX = 20;

export function EChart({ option, height, label }: { option: ChartOption; height: number; label?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const chart = useRef<echarts.ECharts | undefined>(undefined);

  useEffect(() => {
    const element = ref.current!;
    const instance = echarts.init(element, undefined, { renderer: "svg" });
    chart.current = instance;
    const observer = new ResizeObserver(() => instance.resize());
    observer.observe(element);
    return () => {
      observer.disconnect();
      instance.dispose();
      chart.current = undefined;
    };
  }, []);

  useEffect(() => {
    chart.current?.setOption(option, { notMerge: true });
  }, [option]);

  return <div ref={ref} class="echart" style={{ height: `${height}px` }} role="img" aria-label={label} />;
}

const escapeHTML = (text: string): string =>
  text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

export interface TooltipRow {
  label: string;
  value: string;
  color?: string;
}

/** HTML of a chart tooltip: title, then rows of swatch, label and value. */
export function tooltipHTML(title: string, rows: TooltipRow[]): string {
  const body = rows
    .map((r) =>
      `<div class="tt-row">${r.color ? `<span class="tt-swatch" style="background:${r.color}"></span>` : ""}` +
      `<span class="tt-label">${escapeHTML(r.label)}</span><span class="tt-value">${escapeHTML(r.value)}</span></div>`,
    )
    .join("");
  return `<div class="tt"><div class="tt-title">${escapeHTML(title)}</div>${body}</div>`;
}

export function tooltipBase(p: Palette): TooltipComponentOption {
  return {
    // The .tt markup from tooltipHTML draws the box; the ECharts container stays invisible.
    confine: true,
    backgroundColor: "transparent",
    borderWidth: 0,
    padding: 0,
    textStyle: { color: p.text, fontSize: 12, fontFamily: FONT },
    extraCssText: "box-shadow:none;",
    transitionDuration: 0,
  };
}

export function axisTooltip(p: Palette, formatter: (index: number) => string): TooltipComponentOption {
  return {
    ...tooltipBase(p),
    trigger: "axis",
    axisPointer: { type: "line", lineStyle: { color: p.other, opacity: 0.55, width: 1 }, z: 0 },
    formatter: (params: unknown) => {
      const list = Array.isArray(params) ? params : [params];
      const first = list[0] as { dataIndex?: number } | undefined;
      return first?.dataIndex === undefined ? "" : formatter(first.dataIndex);
    },
  };
}

/** Axis styling: no axis line or ticks, secondary labels, hairline grid. */
export function axis(p: Palette, grid = true) {
  return {
    axisLine: { show: false },
    axisTick: { show: false },
    axisLabel: { color: p.text2, fontSize: 11, fontFamily: FONT, hideOverlap: true },
    splitLine: { show: grid, lineStyle: { color: p.hairline, width: 1 } },
  };
}

export const usdAxisLabel = (value: number): string => Fmt.usd(value);
export const tokenAxisLabel = (value: number): string => Fmt.tokens(value);

export function baseOption(p: Palette): ChartOption {
  return {
    animation: false,
    textStyle: { fontFamily: FONT, color: p.text2 },
    grid: { left: 4, right: 12, top: 14, bottom: 4, containLabel: true },
  };
}

/**
 * Stacked bar series with rounded tops on the topmost non-empty segment of each bar only and a
 * thin surface-colored outline, which reads as a 2 px gap between segments.
 */
export function stackedBars(p: Palette, series: { name: string; color: string; values: number[] }[], stack = "total"): BarSeriesOption[] {
  const count = series[0]?.values.length ?? 0;
  const top: number[] = Array.from({ length: count }, (_, i) => {
    for (let s = series.length - 1; s >= 0; s--) if (series[s].values[i] > 0) return s;
    return -1;
  });
  return series.map((s, index) => ({
    type: "bar",
    name: s.name,
    stack,
    barMaxWidth: BAR_MAX,
    barCategoryGap: "28%",
    itemStyle: { color: s.color, borderColor: p.card, borderWidth: series.length > 1 ? 1 : 0 },
    emphasis: { disabled: true },
    // Empty segments are left out (a zero-height bar would still draw its outline).
    data: s.values.map((value, i) => (value > 0 ? { value, itemStyle: top[i] === index ? { borderRadius: [4, 4, 0, 0] } : undefined } : null)),
  }));
}
