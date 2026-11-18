// "Настройки": appearance, sources, account limits, cloud receiver, prices and plan.
// Port of Views/SettingsView.swift, the settings part of AccountLimitsView.swift and CloudReceiverView.swift.
import type { LucideIcon } from "lucide-preact";
import { useEffect, useState } from "preact/hooks";
import { Fmt } from "../../core/fmt";
import { windowFraction, type PlanUsage } from "../../core/plan";
import { displayModelName, familyReferencePrefix, modelFamily } from "../../core/model";
import type { ModelPrice, PricingTable } from "../../core/pricing";
import * as I from "../icons";
import { PLANS, store, useStore } from "../state";
import { C } from "../traceStyle";
import { BrandMark } from "../brand";
import { Button, Card, Chip, Chips, Icon, Label, Legend, Md, Segmented } from "../ui";
import { installStatusLine, uninstallStatusLine } from "./live";
import { tildePath } from "./sources";

const TABS: { id: string; title: string; icon: LucideIcon }[] = [
  { id: "appearance", title: "Оформление", icon: I.Sun },
  { id: "sources", title: "Источники", icon: I.Folder },
  { id: "limits", title: "Лимиты аккаунта", icon: I.Gauge },
  { id: "cloud", title: "Облако", icon: I.CloudDownload },
  { id: "pricing", title: "Цены", icon: I.Zap },
  { id: "plan", title: "Подписка", icon: I.User },
];

export function SettingsView() {
  const s = useStore();
  const tab = TABS.some((t) => t.id === s.settingsTab) ? s.settingsTab : "appearance";
  return (
    <div class="settings">
      <nav class="settings-tabs" role="tablist">
        {TABS.map((t) => (
          <button key={t.id} type="button" role="tab" aria-selected={t.id === tab} class={t.id === tab ? "on" : ""} onClick={() => store.set("settingsTab", t.id)}>
            <Icon icon={t.icon} size={18} />
            <span>{t.title}</span>
          </button>
        ))}
      </nav>
      <div class="settings-body" data-scroll>
        {tab === "appearance" ? <AppearanceSettings />
          : tab === "sources" ? <SourcesSettings />
            : tab === "limits" ? <AccountLimitsSettings />
              : tab === "cloud" ? <CloudReceiverSettings />
                : tab === "pricing" ? <PricingSettings />
                  : <PlanSettings />}
      </div>
    </div>
  );
}

// MARK: Appearance

function AppearanceSettings() {
  const s = useStore();
  return (
    <div class="page narrow">
      <Card title="Тема">
        <div class="stack-10">
          <Segmented value={s.settings.theme} options={[{ id: "s2a", title: "S2A" }, { id: "system", title: "Системная" }]} onChange={(theme) => void s.updateSettings({ theme })} label="Тема" />
          <div class="caption secondary">
            {s.settings.theme === "s2a" ? "Фирменные цвета S2A: фиолетовый, циан и глубокий ночной фон" : "Нейтральная палитра и системный акцент Windows"}
          </div>
          <Segmented
            value={s.settings.appearance}
            options={[{ id: "auto", title: "Как в системе" }, { id: "light", title: "Светлая" }, { id: "dark", title: "Тёмная" }]}
            onChange={(appearance) => void s.updateSettings({ appearance })}
            label="Режим"
          />
        </div>
      </Card>
      <Card title="Палитра"><ThemePreview /></Card>
    </div>
  );
}

function ThemePreview() {
  const p = store.palette;
  return (
    <div class="stack-14">
      <div class="row gap-12">
        <BrandMark size={40} />
        <div class="stack-2">
          <h3>S2A Claude X-Ray</h3>
          <div class="caption secondary">акцент, поверхности и восемь цветов серий</div>
        </div>
      </div>
      <div class="row gap-6">
        {p.series.map((color, i) => (
          <div class="swatch-big" key={i}>
            <span style={{ background: color }} />
            <div class="caption2 secondary">{i + 1}</div>
          </div>
        ))}
      </div>
      <Legend items={[
        { name: "модель", color: C.model }, { name: "вы", color: C.user }, { name: "инструменты", color: C.tool },
        { name: "контекст", color: C.context }, { name: "субагенты", color: C.subagent }, { name: "скиллы", color: C.skill }, { name: "MCP", color: C.mcp },
      ]} />
      <Chips>
        <Chip text="хорошо" icon={I.CircleCheck} tint={C.good} />
        <Chip text="внимание" icon={I.TriangleExclamationPoint} tint={C.warning} />
        <Chip text="серьёзно" icon={I.OctagonExclamationPoint} tint={C.serious} />
        <Chip text="критично" icon={I.OctagonX} tint={C.critical} />
      </Chips>
      <div class="caption secondary">
        Цвета серий подобраны так, чтобы соседние оставались различимы при протанопии и дейтеранопии в светлом и тёмном режиме. Статусные цвета одинаковы во всех темах и всегда идут со значком и подписью.
      </div>
    </div>
  );
}

// MARK: Sources

function SourcesSettings() {
  const s = useStore();
  const exists = new Map((s.scan?.sources ?? []).map((x) => [x.directory, x.exists]));
  const setDirectories = async (directories: string[] | null) => {
    store.directories = await s.bridge.setDirectories(directories);
    store.emit();
  };
  const add = async () => {
    const folder = await s.bridge.pickFolder();
    if (folder && !s.directories.includes(folder)) await setDirectories([...s.directories, folder]);
  };
  return (
    <div class="page narrow">
      <div class="secondary">
        Папки с транскриптами Claude Code (*.jsonl). Обычно это %USERPROFILE%\.claude\projects; если задан CLAUDE_CONFIG_DIR — его подпапка projects. Для Claude Code в WSL добавьте \\wsl$\&lt;дистрибутив&gt;\home\&lt;пользователь&gt;\.claude\projects.
      </div>
      <div class="card flush">
        {s.directories.map((dir) => (
          <div class="list-row" key={dir}>
            <Icon icon={exists.get(dir) === false ? I.FolderSearch : I.Folder} size={16} color={exists.get(dir) === false ? "var(--text3)" : C.accent} />
            <span class="mono selectable grow ellipsis" title={dir}>{dir}</span>
            <button class="btn borderless icon-only" type="button" title="Убрать папку" onClick={() => void setDirectories(s.directories.filter((d) => d !== dir))}>
              <Icon icon={I.Trash} size={14} />
            </button>
          </div>
        ))}
        {s.directories.length === 0 ? <div class="list-row secondary">Папок нет</div> : null}
      </div>
      <div class="row gap-8 wrap">
        <Button onClick={() => void add()}>Добавить папку…</Button>
        <Button onClick={() => void setDirectories(null)}>По умолчанию</Button>
        <Button onClick={() => void s.bridge.importDialog()} title="Скопировать лог сессии (.jsonl или .zip), например облачной, в папку импорта X-Ray">Импортировать лог…</Button>
        <span class="spacer" />
        <Button onClick={() => void s.bridge.fullRescan()}>Пересканировать всё</Button>
      </div>
      {s.scan?.lastScan ? (
        <div class="caption secondary">
          Последнее чтение: файлов {s.scan.filesSeen}, новых строк {s.scan.linesRead}, за {(s.scan.duration / 1000).toFixed(2)} с. Всего запросов в базе: {s.priced.length}.
        </div>
      ) : null}
      {(s.scan?.errors ?? []).map((error) => <div class="caption critical" key={error}>{error}</div>)}
      <div class="caption secondary">Приложение только читает эти файлы и никуда не отправляет данные. Данные X-Ray: {tildePath(s.supportDir)}</div>
    </div>
  );
}

// MARK: Account limits

function AccountLimitsSettings() {
  const s = useStore();
  const [error, setError] = useState<string>();
  useEffect(() => {
    void s.bridge.statusLineState().then((state) => store.set("statusLine", state));
  }, []);
  const state = s.statusLine;
  return (
    <div class="page narrow">
      <div>
        Claude Code после каждого ответа передаёт строке статуса процент 5‑часового и недельного лимита вашего аккаунта. Это реальные цифры подписки: они учитывают чаты, облачные сессии, Cowork и сессии на этом компьютере. X-Ray подключается к строке статуса, запоминает эти цифры и показывает их на экране «Сейчас» и в значке в области уведомлений.
      </div>
      <div class="card">
        <div class="stack-8">
          {state.type === "notInstalled" ? <Label icon={I.CircleDashed} text="Не подключено" />
            : state.type === "otherStatusLine" ? (
              <div class="stack-4">
                <Label icon={I.CircleDashed} text="Не подключено. Сейчас в Claude Code своя строка статуса, X-Ray её сохранит:" />
                <div class="mono caption selectable">{state.command}</div>
              </div>
            ) : state.type === "installed" ? (
              <div class="stack-4">
                <Label icon={I.CircleCheck} class="good-text" text="Подключено" />
                {state.wrapping ? <div class="mono caption selectable">Ваша строка статуса по-прежнему показывается: {state.wrapping}</div> : null}
              </div>
            ) : <Label icon={I.TriangleExclamationPoint} class="critical" text={state.message} />}
          <div class="row gap-8">
            {state.type === "installed" ? <Button onClick={async () => setError(await uninstallStatusLine())}>Отключить</Button>
              : state.type === "unreadable" ? null
                : <Button primary onClick={async () => setError(await installStatusLine())}>Подключить</Button>}
          </div>
          {error ? <div class="caption critical">{error}</div> : null}
        </div>
      </div>
      {s.planUsage ? <div class="caption secondary">{lastReport(s.planUsage, s.now)}</div> : null}
      <div class="caption secondary">
        <Md text={`X-Ray меняет только \`statusLine\` в ${tildePath(s.statusLinePath)}, а прежний файл сохраняет рядом как settings.json.xray-backup. Строку статуса выполняет Claude Code в терминале, в том числе с Remote Control. Если там уже была своя строка статуса, X-Ray оставляет её на экране (через Git Bash, как сам Claude Code) и только запоминает цифры лимитов.`} />
      </div>
      <hr />
      <h3>Облачные сессии</h3>
      <div class="callout secondary">
        Чтобы облачные сессии (claude.ai/code, мобильное приложение, облачная среда Claude Desktop) появлялись здесь вживую, включите приём на вкладке «Облако». Разово можно попросить сессию прислать свой лог («пришли лог сессии для X-Ray») и импортировать файл.
      </div>
      <div><Button onClick={() => void s.bridge.importDialog()}>Импортировать лог сессии…</Button></div>
    </div>
  );
}

function lastReport(usage: PlanUsage, now: number): string {
  const parts = [`Последние цифры: ${Fmt.dateTime(usage.capturedAt)}`];
  if (usage.fiveHour) parts.push(`5 ч ${Fmt.percent(windowFraction(usage.fiveHour, now))}`);
  if (usage.sevenDay) parts.push(`неделя ${Fmt.percent(windowFraction(usage.sevenDay, now))}`);
  if (usage.model) parts.push(`из сессии ${usage.model}` + (usage.version ? `, Claude Code ${usage.version}` : ""));
  return parts.join(" · ");
}

// MARK: Cloud receiver

function CloudReceiverSettings() {
  const s = useStore();
  const [port, setPort] = useState(String(s.settings.receiverPort));
  const [copied, setCopied] = useState(false);
  const status = s.receiver;
  const masked = (token: string) => (token.length <= 12 ? token || "—" : `${token.slice(0, 9)}…${token.slice(-4)}`);
  const applyPort = () => {
    const value = Number(port.trim());
    if (Number.isInteger(value) && value >= 1024 && value <= 65535) void s.updateSettings({ receiverPort: value });
    else setPort(String(s.settings.receiverPort));
  };
  return (
    <div class="page narrow">
      <div>
        Облачные сессии Claude Code могут сами отправлять сюда свой лог после каждого шага: промпты, ответы, размышления, вызовы инструментов, контекст и токены каждого запроса. X-Ray покажет их так же подробно, как сессии на этом компьютере, почти вживую.
      </div>
      <div class="card">
        <div class="stack-10">
          <label class="check">
            <input type="checkbox" checked={s.settings.receiverEnabled} onChange={(e) => void s.updateSettings({ receiverEnabled: (e.currentTarget as HTMLInputElement).checked })} />
            <span>Принимать логи облачных сессий</span>
          </label>
          {!s.settings.receiverEnabled ? <Label icon={I.CircleStop} class="secondary" text="Выключено" />
            : status.error ? <Label icon={I.TriangleExclamationPoint} class="critical" text={`Не удалось открыть порт ${status.port}: ${status.error}`} />
              : status.listening ? (
                <div class="stack-3">
                  <Label icon={I.Radio} class="good-text" text={`Принимает на 127.0.0.1:${status.port}`} />
                  <div class="caption secondary">
                    {status.lastUpload !== undefined ? `Последняя передача ${Fmt.dateTime(status.lastUpload)} · ${status.lastPath ?? ""} · всего строк ${status.lines}` : "Облачные сессии ещё ничего не присылали."}
                  </div>
                  {status.rejectedAuth > 0 ? <div class="caption warning-text">Отклонено запросов с неверным токеном: {status.rejectedAuth}</div> : null}
                </div>
              ) : <Label icon={I.Hourglass} class="secondary" text="Запускается…" />}
          <div class="row gap-8">
            <span class="secondary">Порт</span>
            <input class="input" style={{ width: "80px" }} value={port} onInput={(e) => setPort((e.currentTarget as HTMLInputElement).value)} onBlur={applyPort} onKeyDown={(e) => e.key === "Enter" && applyPort()} />
            <span class="caption secondary">приём только с этого компьютера (127.0.0.1); снаружи — через туннель</span>
          </div>
          <div class="row gap-8">
            <span class="secondary">Токен доступа</span>
            <span class="mono">{masked(s.receiverToken)}</span>
            <Button small onClick={async () => { await s.bridge.copyText(s.receiverToken); setCopied(true); }}>{copied ? "Скопировано" : "Скопировать"}</Button>
            <Button small title="Создать новый токен. Старый перестанет приниматься." onClick={async () => { store.receiverToken = await s.bridge.regenerateToken(); setCopied(false); store.emit(); }}>Новый</Button>
          </div>
        </div>
      </div>
      <h3>Как подключить</h3>
      <Step n={1} text="Сделайте X-Ray доступным из облака. Проще всего через Tailscale Funnel: установите Tailscale для Windows (бесплатно), войдите и выполните в PowerShell команду ниже. Она напечатает адрес вида `https://ваш-компьютер.имя-сети.ts.net`." />
      <CommandBox command={`tailscale funnel --bg ${s.settings.receiverPort}`} />
      <div class="caption secondary"><Md text="Если команда `tailscale` не найдена, она лежит здесь: `C:\Program Files\Tailscale\tailscale.exe`." /></div>
      <Step n={2} text="Напишите в облачной сессии Claude: «Подключи X-Ray: <адрес из шага 1>». Claude настроит облачную среду (вы подтвердите изменение) и попросит токен доступа через защищённую форму: вставьте туда токен отсюда. В чат токен не пишите." />
      <Step n={3} text={`Новые облачные сессии начнут присылать лог сами. Они появятся в «Сессиях», «Обзоре» и Live-трассе, а их логи лежат в \`${tildePath(s.supportDir)}\\cloud\`.`} />
      <div class="caption secondary">
        Лог передаётся только на ваш компьютер через ваш туннель. Пока компьютер спит или X-Ray закрыт, облачная сессия копит новые строки и досылает их со следующим шагом. X-Ray на нескольких компьютерах (Windows и Mac) подключается так же, по адресу каждого: облачные сессии присылают лог на все сразу, и выключенный компьютер не задерживает остальные.
      </div>
    </div>
  );
}

function Step({ n, text }: { n: number; text: string }) {
  return (
    <div class="row top gap-8">
      <span class="step-number">{n}</span>
      <span><Md text={text} /></span>
    </div>
  );
}

/** A shell command with a copy button. */
export function CommandBox({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div class="command-box">
      <span class="mono callout selectable grow">{command}</span>
      <Button small onClick={async () => { await store.bridge.copyText(command); setCopied(true); }}>{copied ? "Скопировано" : "Скопировать"}</Button>
    </div>
  );
}

// MARK: Pricing

type PriceField = "input" | "output" | "cacheRead" | "cacheWrite5m" | "cacheWrite1h";

function PricingSettings() {
  const s = useStore();
  const [prefix, setPrefix] = useState("");
  const table = s.pricing;
  const update = (transform: (t: PricingTable) => PricingTable) => void s.setPricing(transform(structuredClone(table)));
  const setPrice = (modelPrefix: string, field: PriceField, value: number) =>
    update((t) => ({ ...t, models: t.models.map((m) => (m.modelPrefix === modelPrefix ? { ...m, [field]: Math.max(0, value) } : m)) }));
  const add = () => {
    const id = prefix.trim().toLowerCase();
    if (!id || table.models.some((m) => m.modelPrefix === id)) return;
    // Start from the family's reference price so the new row is sensible right away.
    const reference = familyReferencePrefix[modelFamily(id)];
    const base = table.models.find((m) => m.modelPrefix === reference);
    const price: ModelPrice = {
      modelPrefix: id,
      displayName: displayModelName(id),
      input: base?.input ?? 0,
      output: base?.output ?? 0,
      cacheRead: base?.cacheRead ?? 0,
      cacheWrite5m: base?.cacheWrite5m ?? (base?.input ?? 0) * 1.25,
      cacheWrite1h: base?.cacheWrite1h ?? (base?.input ?? 0) * 2,
      note: "Добавлено вручную — проверьте цены.",
    };
    update((t) => ({ ...t, models: [...t.models, price] }));
    setPrefix("");
  };
  const fields: [PriceField, string][] = [["input", "Ввод"], ["output", "Вывод"], ["cacheRead", "Чтение кэша"], ["cacheWrite5m", "Запись 5 мин"], ["cacheWrite1h", "Запись 1 ч"]];
  return (
    <div class="page">
      <div class="secondary">
        USD за 1 млн токенов. {table.sourceNote}. Цены меняются — сверяйте с platform.claude.com/docs/en/about-claude/pricing. На подписке это API-эквивалент, а не списание.
      </div>
      <div class="card flush">
        <div class="table-wrap">
          <table class="table prices">
            <thead>
              <tr>
                <th>Модель</th>
                {fields.map(([, title]) => <th key={title} class="right">{title}</th>)}
                <th />
              </tr>
            </thead>
            <tbody>
              {table.models.map((price) => (
                <tr key={price.modelPrefix} title={price.note ?? ""}>
                  <td>
                    <div>{price.displayName}</div>
                    <div class="caption secondary">{price.modelPrefix}</div>
                  </td>
                  {fields.map(([field]) => (
                    <td key={field} class="right">
                      <PriceInput value={price[field]} onCommit={(v) => setPrice(price.modelPrefix, field, v)} />
                    </td>
                  ))}
                  <td>
                    <button class="btn borderless icon-only" type="button" title="Удалить строку" onClick={() => update((t) => ({ ...t, models: t.models.filter((m) => m.modelPrefix !== price.modelPrefix) }))}>
                      <Icon icon={I.Trash} size={14} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
      <div class="row gap-8">
        <input class="input" style={{ width: "280px" }} placeholder="id модели, например claude-sonnet-4-5" value={prefix} onInput={(e) => setPrefix((e.currentTarget as HTMLInputElement).value)} onKeyDown={(e) => e.key === "Enter" && add()} />
        <Button onClick={add} disabled={!prefix.trim()}>Добавить</Button>
        <span class="spacer" />
        <Button onClick={() => void s.setPricing(null)}>Сбросить к стандартным</Button>
      </div>
    </div>
  );
}

function PriceInput({ value, onCommit }: { value: number; onCommit: (value: number) => void }) {
  const format = (v: number) => String(Math.round(v * 10_000) / 10_000);
  const [text, setText] = useState(format(value));
  useEffect(() => setText(format(value)), [value]);
  const commit = () => {
    const parsed = Number(text.replace(",", ".").trim());
    if (Number.isFinite(parsed) && parsed >= 0 && parsed !== value) onCommit(parsed);
    else setText(format(value));
  };
  return (
    <input
      class="input num right"
      style={{ width: "78px" }}
      value={text}
      onInput={(e) => setText((e.currentTarget as HTMLInputElement).value)}
      onBlur={commit}
      onKeyDown={(e) => e.key === "Enter" && commit()}
    />
  );
}

// MARK: Plan

function PlanSettings() {
  const s = useStore();
  return (
    <div class="page narrow">
      <Card title="Тариф">
        <div class="stack-8">
          {PLANS.map((plan) => (
            <label class="check" key={plan.id}>
              <input type="radio" name="plan" checked={s.settings.plan === plan.id} onChange={() => void s.updateSettings({ plan: plan.id })} />
              <span>{plan.title}</span>
            </label>
          ))}
        </div>
      </Card>
      <div class="card stack-8 secondary">
        <div>
          На Pro и Max лимиты считаются в 5-часовых окнах, которые начинаются с первого запроса, и дополнительно за неделю. Точный размер лимита Anthropic не публикует, и в логах его нет. Поэтому X-Ray показывает API-эквивалент окна и сравнивает его с вашим самым загруженным окном в истории.
        </div>
        <div>Чем меньше API-эквивалент на задачу (кэш, короткий контекст, подходящая модель), тем медленнее расходуется лимит.</div>
      </div>
    </div>
  );
}
