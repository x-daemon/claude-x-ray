// Colors of the S2A and system themes, light and dark (same values as the macOS app's Theme.swift).
// The categorical orders were validated for protan/deutan separation with the dataviz validator.
import type { ThemeName } from "../shared/api";

export interface Palette {
  series: string[];
  other: string;
  sequential: string[];
  page: string;
  sidebar: string;
  card: string;
  hairline: string;
  empty: string;
  accent: string;
  text: string;
  text2: string;
  text3: string;
  roles: { model: string; user: string; tool: string; context: string; subagent: string; skill: string; mcp: string };
  status: { good: string; warning: string; serious: string; critical: string };
}

const dyn = (light: string, dark: string) => ({ light, dark });

const s2aSeries = [
  dyn("#7153DD", "#856AF5"), // S2A violet
  dyn("#05AC7D", "#029E72"), // mint
  dyn("#EE9E10", "#C68206"), // amber
  dyn("#04A3BE", "#06A0BA"), // cyan
  dyn("#E05B4A", "#D95544"), // coral
  dyn("#2A71D6", "#377EE3"), // blue
  dyn("#D14BA0", "#CA449A"), // magenta
  dyn("#6EA518", "#5F9205"), // lime
];

const neutralSeries = [
  dyn("#2A78D6", "#3987E5"), // blue
  dyn("#EB6834", "#D95926"), // orange
  dyn("#1BAF7A", "#199E70"), // aqua
  dyn("#EDA100", "#C98500"), // yellow
  dyn("#E87BA4", "#D55181"), // magenta
  dyn("#008300", "#0CA30C"), // green
  dyn("#6250D6", "#9085E9"), // violet
  dyn("#E34948", "#E66767"), // red
];

const s2aRamp = ["#E6E5FF", "#C7C3F9", "#AAA2F3", "#8F80EB", "#7359DB", "#583FAF", "#402C84"];
const neutralRamp = ["#CDE2FB", "#9EC5F4", "#6DA7EC", "#3987E5", "#256ABF", "#184F95", "#0D366B"];

export const STATUS = { good: "#0CA30C", warning: "#FAB219", serious: "#EC835A", critical: "#D03B3B" };
export const BRAND_GRADIENT = "linear-gradient(45deg, #301172 0%, #7153DD 52%, #0EB1CD 100%)";

export function palette(theme: ThemeName, dark: boolean): Palette {
  const s2a = theme === "s2a";
  const pick = (d: { light: string; dark: string }) => (dark ? d.dark : d.light);
  const series = (s2a ? s2aSeries : neutralSeries).map(pick);
  const ramp = s2a ? s2aRamp : neutralRamp;
  // Near-zero recedes toward the surface in both modes.
  const sequential = dark ? [...ramp].reverse() : ramp;
  const surfaces = s2a
    ? dark
      ? { page: "#0A0B1C", sidebar: "#101129", card: "#14152C", hairline: "#262844", empty: "#1D1F37", accent: "#8F78F7", text: "#ECEBFA", text2: "#A9A7C4", text3: "#76748F" }
      : { page: "#F5F5FB", sidebar: "#EEEDF8", card: "#FBFBFE", hairline: "#E2E1ED", empty: "#ECECF5", accent: "#7153DD", text: "#1C1A33", text2: "#5E5B78", text3: "#8E8BA5" }
    : dark
      ? { page: "#202020", sidebar: "#1B1B1B", card: "#2A2A2A", hairline: "#3A3A38", empty: "#323230", accent: "#4CC2FF", text: "#F3F3F3", text2: "#B8B8B5", text3: "#8A8A87" }
      : { page: "#F3F3F3", sidebar: "#EBEBEB", card: "#FCFCFB", hairline: "#E1E0D9", empty: "#F0EFEC", accent: "#0067C0", text: "#1B1B1B", text2: "#5E5E5B", text3: "#8E8E8A" };
  return {
    series,
    other: "#898781",
    sequential,
    ...surfaces,
    roles: {
      model: series[0],
      user: series[1],
      tool: s2a ? series[3] : series[2],
      context: series[6],
      subagent: s2a ? series[5] : series[4],
      skill: s2a ? series[2] : series[3],
      mcp: s2a ? series[7] : series[6],
    },
    status: STATUS,
  };
}

/** Cost components in stacking order and their colors (the first five series). */
export const COMPONENTS = ["Ввод", "Вывод", "Чтение кэша", "Запись в кэш", "Веб-поиск"] as const;

/** Applies the palette as CSS variables on <html>. */
export function applyPalette(theme: ThemeName, dark: boolean): Palette {
  const p = palette(theme, dark);
  const root = document.documentElement;
  root.dataset.theme = theme;
  root.dataset.mode = dark ? "dark" : "light";
  const vars: Record<string, string> = {
    "--page": p.page, "--sidebar": p.sidebar, "--card": p.card, "--hairline": p.hairline, "--empty": p.empty,
    "--accent": p.accent, "--text": p.text, "--text2": p.text2, "--text3": p.text3, "--other": p.other,
    "--c-model": p.roles.model, "--c-user": p.roles.user, "--c-tool": p.roles.tool, "--c-context": p.roles.context,
    "--c-subagent": p.roles.subagent, "--c-skill": p.roles.skill, "--c-mcp": p.roles.mcp,
    "--good": p.status.good, "--warning": p.status.warning, "--serious": p.status.serious, "--critical": p.status.critical,
    // Token segments, in the cost-component colors: input, output, cache read, cache write; thinking.
    "--seg-input": p.series[0], "--seg-output": p.series[1], "--seg-read": p.series[2], "--seg-write": p.series[3], "--seg-thinking": p.series[5],
  };
  for (const [k, v] of Object.entries(vars)) root.style.setProperty(k, v);
  return p;
}
