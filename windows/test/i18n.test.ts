import { strict as assert } from "node:assert";
import { test } from "node:test";
import { Fmt } from "../src/core/fmt";
import { format, L, labels, N, plural, resolveLanguage, setLanguage, titled, tr } from "../src/core/i18n";
import { PLURALS, STRINGS } from "../src/core/l10n.generated";

test("texts follow the language; Russian is the key itself", () => {
  setLanguage("ru");
  assert.equal(L`Сессии`, "Сессии");
  assert.equal(L`${5} мин назад`, "5 мин назад");
  setLanguage("en");
  assert.equal(L`Сессии`, "Sessions");
  assert.equal(L`${5} мин назад`, "5 min ago");
  setLanguage("de");
  assert.equal(L`${5} мин назад`, "vor 5 Min.");
  assert.equal(tr("Сессии"), "Sitzungen");
  assert.equal(L`Текст, которого нет в каталоге ${1}`, "Текст, которого нет в каталоге 1", "missing keys fall back to Russian");
  setLanguage("ru");
});

test("placeholders are filled in one pass", () => {
  assert.equal(format("{0} и {1}", ["{1}", "b"]), "{1} и b");
  assert.equal(format("{0} {2}", ["a"]), "a {2}");
});

test("plurals: Russian one/few/many, English and German one|other, {n} placement", () => {
  setLanguage("ru");
  assert.deepEqual([1, 2, 5, 11, 21, 22].map((n) => plural(n, "запрос", "запроса", "запросов")),
    ["1 запрос", "2 запроса", "5 запросов", "11 запросов", "21 запрос", "22 запроса"]);
  setLanguage("en");
  assert.deepEqual([1, 2, 21].map((n) => plural(n, "запрос", "запроса", "запросов")), ["1 request", "2 requests", "21 requests"]);
  setLanguage("de");
  assert.equal(Fmt.ago(3 * 86_400), "vor 3 Tagen");
  assert.equal(Fmt.ago(86_400), "vor 1 Tag");
  setLanguage("ru");
});

test("units and dates in each language", () => {
  const ms = new Date(2026, 10, 14, 17, 23).getTime();
  setLanguage("ru");
  assert.equal(Fmt.duration(2 * 3600 + 5 * 60), "2 ч 05 мин");
  assert.equal(Fmt.dateTime(ms), "14.11 17:23");
  setLanguage("en");
  assert.equal(Fmt.duration(2 * 3600 + 5 * 60), "2 h 05 min");
  assert.equal(Fmt.shortDuration(4.25), "4.3 s");
  assert.equal(Fmt.bytes(2048), "2 KB");
  assert.equal(Fmt.dateTime(ms), "14 Nov 17:23");
  assert.equal(Fmt.day(ms), "14 Nov 2026");
  setLanguage("de");
  assert.equal(Fmt.duration(2 * 3600 + 5 * 60), "2 Std. 05 Min.");
  assert.equal(Fmt.dateTime(ms), "14.11. 17:23");
  setLanguage("ru");
});

test("tables built at load time translate when read", () => {
  const severity = labels({ good: N("Хорошо"), other: "Opus" });
  const tabs = titled([{ id: "today", title: N("Сегодня") }]);
  setLanguage("en");
  assert.equal(severity.good, "Good");
  assert.equal(severity.other, "Opus");
  assert.equal(tabs[0].title, "Today");
  setLanguage("de");
  assert.equal(tabs[0].title, "Heute");
  setLanguage("ru");
  assert.equal(severity.good, "Хорошо");
});

test("system language: the first preferred one X-Ray has, else English", () => {
  assert.equal(resolveLanguage("system", ["fr-CH", "de-CH", "en-US"]), "de");
  assert.equal(resolveLanguage("system", ["ru_RU"]), "ru");
  assert.equal(resolveLanguage("system", ["fr-FR"]), "en");
  assert.equal(resolveLanguage("de", ["ru-RU"]), "de");
  assert.equal(resolveLanguage(undefined, []), "en");
});

test("the generated catalog has both languages for every entry", () => {
  for (const [key, entry] of Object.entries(STRINGS)) {
    assert.ok(entry.en && entry.de, key);
  }
  for (const [key, entry] of Object.entries(PLURALS)) {
    assert.equal(entry.en?.split("|").length, 2, key);
    assert.equal(entry.de?.split("|").length, 2, key);
  }
});
