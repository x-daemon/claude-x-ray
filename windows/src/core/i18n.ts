// Interface language for every user-visible string: views, insights, reports, units, the tray.
// Keys are the Russian texts themselves, with {0}, {1}… where values are interpolated. The
// English and German texts live in l10n/strings.json at the repository root, shared with the Mac
// app, and are generated into ./l10n.generated.ts by scripts/l10n.py. Port of XRayCore/L10n.swift.
import { PLURALS, STRINGS } from "./l10n.generated";

export type Language = "ru" | "en" | "de";
/** What the user picked in Settings; "system" follows the operating system's languages. */
export type LanguageSetting = Language | "system";

export const LANGUAGES: readonly Language[] = ["ru", "en", "de"];
/** Each language's name in itself, for the language picker. */
export const LANGUAGE_NAMES: Record<Language, string> = { ru: "Русский", en: "English", de: "Deutsch" };

let current: Language = "ru";

export function setLanguage(language: Language): void {
  current = language;
}

export function language(): Language {
  return current;
}

/** "system" becomes the first of the user's preferred languages that X-Ray has, else English. */
export function resolveLanguage(setting: LanguageSetting | undefined, preferred: readonly string[]): Language {
  if (setting && setting !== "system") return setting;
  for (const tag of preferred) {
    const code = tag.toLowerCase().split(/[-_]/)[0];
    if ((LANGUAGES as readonly string[]).includes(code)) return code as Language;
  }
  return "en";
}

function lookup(key: string): string {
  if (current === "ru") return key;
  return STRINGS[key]?.[current] ?? key;
}

/** Fills {0}, {1}… in one pass, so an argument that itself contains "{1}" stays as it is. */
export function format(template: string, args: readonly unknown[]): string {
  if (args.length === 0) return template;
  return template.replace(/\{(\d+)\}/g, (match, index: string) => {
    const i = Number(index);
    return i < args.length ? String(args[i]) : match;
  });
}

const templateKeys = new WeakMap<TemplateStringsArray, string>();

/** L`Всего ${n} запросов` looks up "Всего {0} запросов" and fills in n. */
export function L(strings: TemplateStringsArray, ...values: unknown[]): string {
  let key = templateKeys.get(strings);
  if (key === undefined) {
    key = strings[0];
    for (let i = 1; i < strings.length; i++) key += `{${i - 1}}` + strings[i];
    templateKeys.set(strings, key);
  }
  return format(lookup(key), values);
}

/** Translates a Russian text kept in data (a label table, a constant): tr(item.title). */
export function tr(key: string, ...args: unknown[]): string {
  return format(lookup(key), args);
}

/** Marks a Russian text for the catalog without translating it yet: a table built at load time,
 * or a name used as an identifier (a tool category). The place that shows it calls tr(). */
export const N = <T extends string>(key: T): T => key;

/** A label table built at load time whose values are translated each time they are read:
 * labels({ good: N("Хорошо") }).good is "Good" in English. */
export function labels<K extends string>(table: Record<K, string>): Readonly<Record<K, string>> {
  return new Proxy(table, {
    get: (target, key) => (typeof key === "string" && key in target ? tr(target[key as K]) : undefined),
  });
}

/** A list of { title: N("…") } items whose titles are translated each time they are read. */
export function titled<T extends { title: string }>(items: T[]): T[] {
  return items.map((item) => Object.defineProperty({ ...item }, "title", { get: () => tr(item.title), enumerable: true }));
}

/**
 * The form of a counted word: Russian one/few/many (1 запрос, 2 запроса, 5 запросов); the
 * catalog gives English and German one|other. A form that contains {n} places the number itself
 * (German "vor {n} Tagen"); otherwise the number goes first.
 */
export function plural(count: number, one: string, few: string, many: string): string {
  let form: string;
  if (current === "ru") {
    const n = Math.abs(count) % 100;
    const last = n % 10;
    form = n >= 11 && n <= 14 ? many : last === 1 ? one : last >= 2 && last <= 4 ? few : many;
  } else {
    const forms = (PLURALS[`${one}|${few}|${many}`]?.[current] ?? `${one}|${many}`).split("|");
    form = Math.abs(count) === 1 ? forms[0] : forms[forms.length - 1];
  }
  return form.includes("{n}") ? form.replace("{n}", String(count)) : `${count} ${form}`;
}
