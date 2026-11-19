// Formatting helpers shared by the app, reports and tests. Port of XRayCore/Util/Fmt.swift.
import { L, language, plural } from "./i18n";

/** Rounds half away from zero, like Swift's rounded(). */
export const roundHalfAway = (x: number): number => Math.sign(x) * Math.round(Math.abs(x));

function trimmed(value: number, digits: number): string {
  let text = value.toFixed(digits);
  if (text.includes(".")) {
    text = text.replace(/0+$/, "");
    if (text.endsWith(".")) text = text.slice(0, -1);
  }
  return text;
}

function grouped(value: number): string {
  const digits = String(Math.abs(value));
  let out = "";
  for (let i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 === 0) out += ",";
    out += digits[i];
  }
  return (value < 0 ? "-" : "") + out;
}

const pad2 = (n: number): string => String(n).padStart(2, "0");

const MONTHS_EN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** 14.11 in Russian, 14.11. in German, 14 Nov in English: a numeric 11/14 would be misread. */
function dayMonth(d: Date): string {
  switch (language()) {
    case "en": return `${d.getDate()} ${MONTHS_EN[d.getMonth()]}`;
    case "de": return `${pad2(d.getDate())}.${pad2(d.getMonth() + 1)}.`;
    default: return `${pad2(d.getDate())}.${pad2(d.getMonth() + 1)}`;
  }
}

export const Fmt = {
  /** $0.42, $12.30, $1,234. */
  usd(value: number): string {
    const magnitude = Math.abs(value);
    if (magnitude >= 1000) return "$" + grouped(roundHalfAway(value));
    if (magnitude > 0 && magnitude < 0.01) return value < 0 ? "-<$0.01" : "<$0.01";
    return (value < 0 ? "-$" : "$") + Math.abs(value).toFixed(2);
  },

  /** 950, 12.3K, 4.56M, 1.2B. */
  tokens(value: number): string {
    const v = Math.abs(value);
    if (v >= 1_000_000_000) return trimmed(value / 1_000_000_000, 2) + "B";
    if (v >= 1_000_000) return trimmed(value / 1_000_000, 2) + "M";
    if (v >= 1_000) return trimmed(value / 1_000, 1) + "K";
    return String(Math.trunc(value));
  },

  /** 0.385 -> 39%; small shares keep one decimal (4.2%). */
  percent(fraction: number): string {
    const value = fraction * 100;
    if (value > 0 && value < 10) return trimmed(value, 1) + "%";
    return `${roundHalfAway(value)}%`;
  },

  /** 2 ч 05 мин, 14 мин, 40 с. Input in seconds. */
  duration(seconds: number): string {
    const s = roundHalfAway(Math.max(0, seconds));
    const hours = Math.floor(s / 3600);
    const minutes = Math.floor((s % 3600) / 60);
    if (hours > 0) return L`${hours} ч ${pad2(minutes)} мин`;
    if (minutes > 0) return L`${minutes} мин`;
    return L`${s} с`;
  },

  /** Short durations for steps and tools: 850 мс, 4.2 с, 3 мин 05 с, 1 ч 02 мин. Seconds. */
  shortDuration(seconds: number): string {
    const value = Math.max(0, seconds);
    if (value < 1) return L`${roundHalfAway(value * 1000)} мс`;
    if (value < 60) return L`${trimmed(value, 1)} с`;
    const s = roundHalfAway(value);
    if (s < 3600) return L`${Math.floor(s / 60)} мин ${pad2(s % 60)} с`;
    return Fmt.duration(value);
  },

  /** Milliseconds from transcripts: 2128 -> 2.1 с. */
  ms(milliseconds: number): string {
    return Fmt.shortDuration(milliseconds / 1000);
  },

  /** 820 Б, 12.3 КБ, 4.5 МБ. */
  bytes(count: number): string {
    if (count < 1024) return L`${count} Б`;
    if (count < 1024 * 1024) return L`${trimmed(count / 1024, 1)} КБ`;
    return L`${trimmed(count / 1024 / 1024, 1)} МБ`;
  },

  /** A count with its word, given in Russian one/few/many: plural(5, "раз", "раза", "раз") -> 5 раз;
   * in English and German the catalog's one|other forms. */
  plural(count: number, one: string, few: string, many: string): string {
    return plural(count, one, few, many);
  },

  /** Time until an event: 45 мин, 2 ч 10 мин, 3 дня 4 ч. Seconds. */
  span(seconds: number): string {
    const value = Math.max(0, seconds);
    if (value < 86_400) return Fmt.duration(value);
    const days = Math.floor(value / 86_400);
    const hours = Math.floor((value % 86_400) / 3600);
    const dayText = Fmt.plural(days, "день", "дня", "дней");
    return hours > 0 ? L`${dayText} ${hours} ч` : dayText;
  },

  /** How long ago: только что, 12 мин назад, 3 ч назад, 4 дня назад. Seconds. */
  ago(seconds: number): string {
    const value = Math.max(0, seconds);
    if (value < 60) return L`только что`;
    if (value < 3600) return L`${Math.floor(value / 60)} мин назад`;
    if (value < 86_400) return L`${Math.floor(value / 3600)} ч назад`;
    return Fmt.plural(Math.floor(value / 86_400), "день назад", "дня назад", "дней назад");
  },

  /** 14.11 17:23 in local time (14 Nov 17:23 in English, 14.11. 17:23 in German). */
  dateTime(ms: number): string {
    const d = new Date(ms);
    return `${dayMonth(d)} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  },

  /** 14.11 in local time (14 Nov in English, 14.11. in German). */
  dayMonth(ms: number): string {
    return dayMonth(new Date(ms));
  },

  /** 17:23:05 in local time. */
  time(ms: number, seconds = true): string {
    const d = new Date(ms);
    return `${pad2(d.getHours())}:${pad2(d.getMinutes())}` + (seconds ? `:${pad2(d.getSeconds())}` : "");
  },

  /** 2026-11-14 in local time. */
  isoDay(ms: number): string {
    const d = new Date(ms);
    return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  },

  /** 14.11.2026 in local time (14 Nov 2026 in English). */
  day(ms: number): string {
    const d = new Date(ms);
    return language() === "en" ? `${d.getDate()} ${MONTHS_EN[d.getMonth()]} ${d.getFullYear()}` : `${pad2(d.getDate())}.${pad2(d.getMonth() + 1)}.${d.getFullYear()}`;
  },

  /** Plain decimal for CSV, independent of locale. */
  decimal(value: number, digits = 4): string {
    return value.toFixed(digits);
  },
};
