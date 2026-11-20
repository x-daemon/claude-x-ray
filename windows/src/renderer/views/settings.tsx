// "Настройки": appearance, sources, account limits, cloud receiver, prices and plan.
// Port of Views/SettingsView.swift, the settings part of AccountLimitsView.swift and CloudReceiverView.swift.
import type { LucideIcon } from "lucide-preact";
import { useEffect, useState } from "preact/hooks";
import qrcode from "qrcode-generator";
import { viewerLink } from "../../core/viewerLink";
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
import { L, LANGUAGE_NAMES, LANGUAGES, N, titled, tr } from "../../core/i18n";

const TABS: { id: string; title: string; icon: LucideIcon }[] = titled([
  { id: "appearance", title: N("Язык и оформление"), icon: I.Sun },
  { id: "sources", title: N("Источники"), icon: I.Folder },
  { id: "limits", title: N("Лимиты аккаунта"), icon: I.Gauge },
  { id: "cloud", title: N("Облако"), icon: I.CloudDownload },
  { id: "ipad", title: "iPad", icon: I.Tablet },
  { id: "pricing", title: N("Цены"), icon: I.Zap },
  { id: "plan", title: N("Подписка"), icon: I.User },
]);

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
                : tab === "ipad" ? <IPadSettings />
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
      <Card title={L`Язык интерфейса`}>
        <div class="stack-10">
          <Segmented
            value={s.settings.language}
            options={[{ id: "system", title: L`Как в системе` }, ...LANGUAGES.map((id) => ({ id, title: LANGUAGE_NAMES[id] }))]}
            onChange={(language) => void s.updateSettings({ language })}
            label={L`Язык интерфейса`}
          />
          <div class="caption secondary">{L`Меню, подсказки, разбор сессий и отчёты. «Как в системе» берёт язык Windows: русский, английский или немецкий, для других языков — английский.`}</div>
        </div>
      </Card>
      <Card title={L`Тема`}>
        <div class="stack-10">
          <Segmented value={s.settings.theme} options={[{ id: "s2a", title: "S2A" }, { id: "system", title: L`Системная` }]} onChange={(theme) => void s.updateSettings({ theme })} label={L`Тема`} />
          <div class="caption secondary">
            {s.settings.theme === "s2a" ? L`Фирменные цвета S2A: фиолетовый, циан и глубокий ночной фон` : L`Нейтральная палитра и системный акцент Windows`}
          </div>
          <Segmented
            value={s.settings.appearance}
            options={[{ id: "auto", title: L`Как в системе` }, { id: "light", title: L`Светлая` }, { id: "dark", title: L`Тёмная` }]}
            onChange={(appearance) => void s.updateSettings({ appearance })}
            label={L`Режим`}
          />
        </div>
      </Card>
      <Card title={L`Палитра`}><ThemePreview /></Card>
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
          <div class="caption secondary">{L`акцент, поверхности и восемь цветов серий`}</div>
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
        { name: L`модель`, color: C.model }, { name: L`вы`, color: C.user }, { name: L`инструменты`, color: C.tool },
        { name: L`контекст`, color: C.context }, { name: L`субагенты`, color: C.subagent }, { name: L`скиллы`, color: C.skill }, { name: "MCP", color: C.mcp },
      ]} />
      <Chips>
        <Chip text={L`хорошо`} icon={I.CircleCheck} tint={C.good} />
        <Chip text={L`внимание`} icon={I.TriangleExclamationPoint} tint={C.warning} />
        <Chip text={L`серьёзно`} icon={I.OctagonExclamationPoint} tint={C.serious} />
        <Chip text={L`критично`} icon={I.OctagonX} tint={C.critical} />
      </Chips>
      <div class="caption secondary">
        {L`Цвета серий подобраны так, чтобы соседние оставались различимы при протанопии и дейтеранопии в светлом и тёмном режиме. Статусные цвета одинаковы во всех темах и всегда идут со значком и подписью.`}
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
        {L`Папки с транскриптами Claude Code (*.jsonl). Обычно это %USERPROFILE%\\.claude\\projects; если задан CLAUDE_CONFIG_DIR — его подпапка projects. Для Claude Code в WSL добавьте \\\\wsl$\\<дистрибутив>\\home\\<пользователь>\\.claude\\projects.`}
      </div>
      <div class="card flush">
        {s.directories.map((dir) => (
          <div class="list-row" key={dir}>
            <Icon icon={exists.get(dir) === false ? I.FolderSearch : I.Folder} size={16} color={exists.get(dir) === false ? "var(--text3)" : C.accent} />
            <span class="mono selectable grow ellipsis" title={dir}>{dir}</span>
            <button class="btn borderless icon-only" type="button" title={L`Убрать папку`} onClick={() => void setDirectories(s.directories.filter((d) => d !== dir))}>
              <Icon icon={I.Trash} size={14} />
            </button>
          </div>
        ))}
        {s.directories.length === 0 ? <div class="list-row secondary">{L`Папок нет`}</div> : null}
      </div>
      <div class="row gap-8 wrap">
        <Button onClick={() => void add()}>{L`Добавить папку…`}</Button>
        <Button onClick={() => void setDirectories(null)}>{L`По умолчанию`}</Button>
        <Button onClick={() => void s.bridge.importDialog()} title={L`Скопировать лог сессии (.jsonl или .zip), например облачной, в папку импорта X-Ray`}>{L`Импортировать лог…`}</Button>
        <span class="spacer" />
        <Button onClick={() => void s.bridge.fullRescan()}>{L`Пересканировать всё`}</Button>
      </div>
      {s.scan?.lastScan ? (
        <div class="caption secondary">
          {L`Последнее чтение: файлов ${s.scan.filesSeen}, новых строк ${s.scan.linesRead}, за ${(s.scan.duration / 1000).toFixed(2)} с. Всего запросов в базе: ${s.priced.length}.`}
        </div>
      ) : null}
      {(s.scan?.errors ?? []).map((error) => <div class="caption critical" key={error}>{error}</div>)}
      <div class="caption secondary">{L`Приложение только читает эти файлы и никуда не отправляет данные. Данные X-Ray: ${tildePath(s.supportDir)}`}</div>
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
        {L`Claude Code после каждого ответа передаёт строке статуса процент 5‑часового и недельного лимита вашего аккаунта. Это реальные цифры подписки: они учитывают чаты, облачные сессии, Cowork и сессии на этом компьютере. X-Ray подключается к строке статуса, запоминает эти цифры и показывает их на экране «Сейчас» и в значке в области уведомлений.`}
      </div>
      <div class="card">
        <div class="stack-8">
          {state.type === "notInstalled" ? <Label icon={I.CircleDashed} text={L`Не подключено`} />
            : state.type === "otherStatusLine" ? (
              <div class="stack-4">
                <Label icon={I.CircleDashed} text={L`Не подключено. Сейчас в Claude Code своя строка статуса, X-Ray её сохранит:`} />
                <div class="mono caption selectable">{state.command}</div>
              </div>
            ) : state.type === "installed" ? (
              <div class="stack-4">
                <Label icon={I.CircleCheck} class="good-text" text={L`Подключено`} />
                {state.wrapping ? <div class="mono caption selectable">{L`Ваша строка статуса по-прежнему показывается: ${state.wrapping}`}</div> : null}
              </div>
            ) : <Label icon={I.TriangleExclamationPoint} class="critical" text={state.message} />}
          <div class="row gap-8">
            {state.type === "installed" ? <Button onClick={async () => setError(await uninstallStatusLine())}>{L`Отключить`}</Button>
              : state.type === "unreadable" ? null
                : <Button primary onClick={async () => setError(await installStatusLine())}>{L`Подключить`}</Button>}
          </div>
          {error ? <div class="caption critical">{error}</div> : null}
        </div>
      </div>
      {s.planUsage ? <div class="caption secondary">{lastReport(s.planUsage, s.now)}</div> : null}
      <div class="caption secondary">
        <Md text={L`X-Ray меняет только \`statusLine\` в ${tildePath(s.statusLinePath)}, а прежний файл сохраняет рядом как settings.json.xray-backup. Строку статуса выполняет Claude Code в терминале, в том числе с Remote Control. Если там уже была своя строка статуса, X-Ray оставляет её на экране (через Git Bash, как сам Claude Code) и только запоминает цифры лимитов.`} />
      </div>
      <hr />
      <h3>{L`Облачные сессии`}</h3>
      <div class="callout secondary">
        {L`Чтобы облачные сессии (claude.ai/code, мобильное приложение, облачная среда Claude Desktop) появлялись здесь вживую, включите приём на вкладке «Облако». Разово можно попросить сессию прислать свой лог («пришли лог сессии для X-Ray») и импортировать файл.`}
      </div>
      <div><Button onClick={() => void s.bridge.importDialog()}>{L`Импортировать лог сессии…`}</Button></div>
    </div>
  );
}

function lastReport(usage: PlanUsage, now: number): string {
  const parts = [L`Последние цифры: ${Fmt.dateTime(usage.capturedAt)}`];
  if (usage.fiveHour) parts.push(L`5 ч ${Fmt.percent(windowFraction(usage.fiveHour, now))}`);
  if (usage.sevenDay) parts.push(L`неделя ${Fmt.percent(windowFraction(usage.sevenDay, now))}`);
  if (usage.model) parts.push(L`из сессии ${usage.model}` + (usage.version ? `, Claude Code ${usage.version}` : ""));
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
        {L`Облачные сессии Claude Code могут сами отправлять сюда свой лог после каждого шага: промпты, ответы, размышления, вызовы инструментов, контекст и токены каждого запроса. X-Ray покажет их так же подробно, как сессии на этом компьютере, почти вживую.`}
      </div>
      <div class="card">
        <div class="stack-10">
          <label class="check">
            <input type="checkbox" checked={s.settings.receiverEnabled} onChange={(e) => void s.updateSettings({ receiverEnabled: (e.currentTarget as HTMLInputElement).checked })} />
            <span>{L`Принимать логи облачных сессий`}</span>
          </label>
          {!s.settings.receiverEnabled ? <Label icon={I.CircleStop} class="secondary" text={L`Выключено`} />
            : status.error ? <Label icon={I.TriangleExclamationPoint} class="critical" text={L`Не удалось открыть порт ${status.port}: ${status.error}`} />
              : status.listening ? (
                <div class="stack-3">
                  <Label icon={I.Radio} class="good-text" text={L`Принимает на 127.0.0.1:${status.port}`} />
                  <div class="caption secondary">
                    {status.lastUpload !== undefined ? L`Последняя передача ${Fmt.dateTime(status.lastUpload)} · ${status.lastPath ?? ""} · всего строк ${status.lines}` : L`Облачные сессии ещё ничего не присылали.`}
                  </div>
                  {status.rejectedAuth > 0 ? <div class="caption warning-text">{L`Отклонено запросов с неверным токеном: ${status.rejectedAuth}`}</div> : null}
                </div>
              ) : <Label icon={I.Hourglass} class="secondary" text={L`Запускается…`} />}
          <div class="row gap-8">
            <span class="secondary">{L`Порт`}</span>
            <input class="input" style={{ width: "80px" }} value={port} onInput={(e) => setPort((e.currentTarget as HTMLInputElement).value)} onBlur={applyPort} onKeyDown={(e) => e.key === "Enter" && applyPort()} />
            <span class="caption secondary">{L`приём только с этого компьютера (127.0.0.1); снаружи — через туннель`}</span>
          </div>
          <div class="row gap-8">
            <span class="secondary">{L`Токен доступа`}</span>
            <span class="mono">{masked(s.receiverToken)}</span>
            <Button small onClick={async () => { await s.bridge.copyText(s.receiverToken); setCopied(true); }}>{copied ? L`Скопировано` : L`Скопировать`}</Button>
            <Button small title={L`Создать новый токен. Старый перестанет приниматься.`} onClick={async () => { store.receiverToken = await s.bridge.regenerateToken(); setCopied(false); store.emit(); }}>{L`Новый`}</Button>
          </div>
        </div>
      </div>
      <h3>{L`Как подключить`}</h3>
      <Step n={1} text={L`Сделайте X-Ray доступным из облака. Проще всего через Tailscale Funnel: установите Tailscale для Windows (бесплатно), войдите и выполните в PowerShell команду ниже. Она напечатает адрес вида \`https://ваш-компьютер.имя-сети.ts.net\`.`} />
      <CommandBox command={`tailscale funnel --bg ${s.settings.receiverPort}`} />
      <div class="caption secondary"><Md text={L`Если команда \`tailscale\` не найдена, она лежит здесь: \`C:\\Program Files\\Tailscale\\tailscale.exe\`.`} /></div>
      <Step n={2} text={L`Напишите в облачной сессии Claude: «Подключи X-Ray: <адрес из шага 1>». Claude настроит облачную среду (вы подтвердите изменение) и попросит токен доступа через защищённую форму: вставьте туда токен отсюда. В чат токен не пишите.`} />
      <Step n={3} text={L`Новые облачные сессии начнут присылать лог сами. Они появятся в «Сессиях», «Обзоре» и Live-трассе, а их логи лежат в \`${tildePath(s.supportDir)}\\cloud\`.`} />
      <div class="caption secondary">
        {L`Лог передаётся только на ваш компьютер через ваш туннель. Пока компьютер спит или X-Ray закрыт, облачная сессия копит новые строки и досылает их со следующим шагом. X-Ray на нескольких компьютерах (Windows и Mac) подключается так же, по адресу каждого: облачные сессии присылают лог на все сразу, и выключенный компьютер не задерживает остальные.`}
      </div>
    </div>
  );
}

// MARK: iPad

function IPadSettings() {
  const s = useStore();
  const [address, setAddress] = useState(s.settings.viewerAddress);
  const [copied, setCopied] = useState<string>();
  const status = s.receiver;
  const masked = (token: string) => (token.length <= 12 ? token || "—" : `${token.slice(0, 10)}…${token.slice(-4)}`);
  useEffect(() => {
    if (!s.detectedAddress) void s.bridge.detectAddress().then((found) => { if (found) { store.detectedAddress = found; store.emit(); } });
  }, []);
  const saveAddress = () => {
    if (address.trim() !== s.settings.viewerAddress) void s.updateSettings({ viewerAddress: address.trim() });
  };
  const link = s.settings.viewerEnabled ? viewerLink(address.trim() || s.detectedAddress || "", s.viewerToken, s.computerName) : undefined;
  const hint = address.trim()
    ? L`Адрес, по которому iPad находит этот компьютер: адрес из \`tailscale funnel\` или \`tailscale serve\`.`
    : s.detectedAddress
      ? L`Найден в Tailscale: ${s.detectedAddress}. Впишите другой, если iPad видит этот компьютер по другому адресу.`
      : L`Tailscale не найден. Впишите адрес, по которому iPad находит этот компьютер, например из \`tailscale funnel\`.`;
  return (
    <div class="page narrow">
      <div>
        {L`X-Ray для iPad показывает всё то же, что и здесь: Live-трассу, сессии, обзор, оптимизацию и отчёты. Он копирует логи с этого компьютера и считает всё сам. Доступ только на чтение и со своим токеном: токен облачных сессий читать логи не может.`}
      </div>
      <div class="card">
        <div class="stack-10">
          <label class="check">
            <input type="checkbox" checked={s.settings.viewerEnabled} onChange={(e) => void s.updateSettings({ viewerEnabled: (e.currentTarget as HTMLInputElement).checked })} />
            <span>{L`Разрешить iPad читать логи`}</span>
          </label>
          {!s.settings.viewerEnabled ? <Label icon={I.CircleStop} class="secondary" text={L`Выключено`} />
            : status.error ? <Label icon={I.TriangleExclamationPoint} class="critical" text={L`Не удалось открыть порт ${status.port}: ${status.error}`} />
              : status.listening ? (
                <div class="stack-3">
                  <Label icon={I.Tablet} class="good-text" text={L`Ждёт iPad на 127.0.0.1:${status.port}`} />
                  <div class="caption secondary">
                    {status.lastViewerRequest !== undefined ? L`iPad последний раз обращался ${Fmt.ago((Date.now() - status.lastViewerRequest) / 1000)} · запросов ${status.viewerRequests}` : L`iPad ещё не подключался.`}
                  </div>
                  {status.viewerRejected > 0 ? <div class="caption warning-text">{L`Отклонено запросов с неверным токеном: ${status.viewerRejected}`}</div> : null}
                </div>
              ) : <Label icon={I.Hourglass} class="secondary" text={L`Запускается…`} />}
          <div class="row gap-8">
            <span class="secondary">{L`Адрес`}</span>
            <input class="input grow" value={address} placeholder={s.detectedAddress ?? L`https://ваш-компьютер.имя-сети.ts.net`}
              onInput={(e) => setAddress((e.currentTarget as HTMLInputElement).value)} onBlur={saveAddress} onKeyDown={(e) => e.key === "Enter" && saveAddress()} />
            <Button small title={L`Взять адрес этого компьютера из Tailscale`} onClick={async () => { store.detectedAddress = await s.bridge.detectAddress(); store.emit(); }}>{L`Найти`}</Button>
          </div>
          <div class="caption secondary"><Md text={hint} /></div>
          <div class="row gap-8">
            <span class="secondary">{L`Токен iPad`}</span>
            <span class="mono">{masked(s.viewerToken)}</span>
            <Button small onClick={async () => { await s.bridge.copyText(s.viewerToken); setCopied("token"); }}>{copied === "token" ? L`Скопировано` : L`Скопировать`}</Button>
            <Button small title={L`Создать новый токен. iPad придётся подключить заново.`} onClick={async () => { store.viewerToken = await s.bridge.regenerateViewerToken(); setCopied(undefined); store.emit(); }}>{L`Новый`}</Button>
          </div>
        </div>
      </div>
      {link ? (
        <div class="row top gap-16">
          <div class="qr-box"><QRCode text={link} /></div>
          <div class="stack-8">
            <h3>{L`Наведите камеру iPad на код`}</h3>
            <div>{L`Камера предложит открыть ссылку в X-Ray, и iPad подключится к этому компьютеру. Или скопируйте ссылку и вставьте её в X-Ray на iPad: «Настройки → Компьютеры → Добавить».`}</div>
            <div><Button small onClick={async () => { await s.bridge.copyText(link); setCopied("link"); }}>{copied === "link" ? L`Скопировано` : L`Скопировать ссылку`}</Button></div>
            <div class="caption secondary">{L`В ссылке есть токен: кто её получит, сможет читать ваши логи. Если она попала не туда, создайте новый токен.`}</div>
          </div>
        </div>
      ) : null}
      <h3>{L`Как подключить`}</h3>
      <Step n={1} text={L`Сделайте X-Ray доступным для iPad. Если облачные сессии уже подключены, это сделано: iPad использует тот же адрес. Иначе установите Tailscale для Windows (бесплатно), войдите и выполните в PowerShell команду ниже.`} />
      <CommandBox command={`tailscale funnel --bg ${s.settings.receiverPort}`} />
      <Step n={2} text={L`Установите X-Ray на iPad из Xcode на Mac: откройте \`iPad/XRay.xcodeproj\` из репозитория, выберите свой Apple ID в Signing и запустите на iPad. Подробно — в README.`} />
      <Step n={3} text={L`Включите доступ выше и отсканируйте код камерой iPad. X-Ray на iPad скачает логи за выбранный период и дальше будет догружать новые строки каждые несколько секунд, пока открыт.`} />
      <div class="caption secondary">
        {L`Логи идут только с вашего компьютера на ваш iPad через ваш туннель. Компьютер с X-Ray должен быть включён; пока он спит, iPad показывает то, что успел скачать. iPad может читать несколько компьютеров сразу, например этот и Mac.`}
      </div>
    </div>
  );
}

/** A QR code drawn as SVG squares, black on white so cameras read it in either theme. */
function QRCode({ text, size = 180 }: { text: string; size?: number }) {
  const qr = qrcode(0, "M");
  qr.addData(text);
  qr.make();
  const count = qr.getModuleCount();
  let d = "";
  for (let r = 0; r < count; r++) for (let c = 0; c < count; c++) if (qr.isDark(r, c)) d += `M${c} ${r}h1v1h-1z`;
  return (
    <svg width={size} height={size} viewBox={`-2 -2 ${count + 4} ${count + 4}`} shape-rendering="crispEdges" role="img" aria-label={L`QR-код для подключения iPad`}>
      <rect x={-2} y={-2} width={count + 4} height={count + 4} fill="#ffffff" />
      <path d={d} fill="#000000" />
    </svg>
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
      <Button small onClick={async () => { await store.bridge.copyText(command); setCopied(true); }}>{copied ? L`Скопировано` : L`Скопировать`}</Button>
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
      note: N("Добавлено вручную — проверьте цены."),
    };
    update((t) => ({ ...t, models: [...t.models, price] }));
    setPrefix("");
  };
  const fields: [PriceField, string][] = [["input", L`Ввод`], ["output", L`Вывод`], ["cacheRead", L`Чтение кэша`], ["cacheWrite5m", L`Запись 5 мин`], ["cacheWrite1h", L`Запись 1 ч`]];
  return (
    <div class="page">
      <div class="secondary">
        {L`USD за 1 млн токенов. ${tr(table.sourceNote)}. Цены меняются — сверяйте с platform.claude.com/docs/en/about-claude/pricing. На подписке это API-эквивалент, а не списание.`}
      </div>
      <div class="card flush">
        <div class="table-wrap">
          <table class="table prices">
            <thead>
              <tr>
                <th>{L`Модель`}</th>
                {fields.map(([, title]) => <th key={title} class="right">{title}</th>)}
                <th />
              </tr>
            </thead>
            <tbody>
              {table.models.map((price) => (
                <tr key={price.modelPrefix} title={price.note ? tr(price.note) : ""}>
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
                    <button class="btn borderless icon-only" type="button" title={L`Удалить строку`} onClick={() => update((t) => ({ ...t, models: t.models.filter((m) => m.modelPrefix !== price.modelPrefix) }))}>
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
        <input class="input" style={{ width: "280px" }} placeholder={L`id модели, например claude-sonnet-4-5`} value={prefix} onInput={(e) => setPrefix((e.currentTarget as HTMLInputElement).value)} onKeyDown={(e) => e.key === "Enter" && add()} />
        <Button onClick={add} disabled={!prefix.trim()}>{L`Добавить`}</Button>
        <span class="spacer" />
        <Button onClick={() => void s.setPricing(null)}>{L`Сбросить к стандартным`}</Button>
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
      <Card title={L`Тариф`}>
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
          {L`На Pro и Max лимиты считаются в 5-часовых окнах, которые начинаются с первого запроса, и дополнительно за неделю. Точный размер лимита Anthropic не публикует, и в логах его нет. Поэтому X-Ray показывает API-эквивалент окна и сравнивает его с вашим самым загруженным окном в истории.`}
        </div>
        <div>{L`Чем меньше API-эквивалент на задачу (кэш, короткий контекст, подходящая модель), тем медленнее расходуется лимит.`}</div>
      </div>
    </div>
  );
}
