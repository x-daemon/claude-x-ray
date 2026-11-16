// Explains an empty screen: which folders X-Ray reads, what they hold, when Claude Code last
// wrote a log on this computer, and how cloud sessions get here. Port of Views/SourcesHelpView.swift.
import type { LucideIcon } from "lucide-preact";
import type { SourceStat } from "../../core/ingest";
import { Fmt } from "../../core/fmt";
import * as I from "../icons";
import { store, useStore } from "../state";
import { C } from "../traceStyle";
import { Button, Card, Icon, Md } from "../ui";
import { openSettings } from "./live";

export function SourcesHelp({ title, icon, message }: { title: string; icon: LucideIcon; message?: string }) {
  const s = useStore();
  const newest = s.newestTranscript;
  return (
    <div class="page narrow">
      <div class="help-head">
        <Icon icon={icon} size={40} class="secondary light" />
        <h2>{title}</h2>
        <div class="secondary">
          {newest ? `Последняя запись в логах на этом компьютере: ${Fmt.dateTime(newest)}, ${Fmt.ago((s.now - newest) / 1000)}.` : "На этом компьютере пока нет ни одного лога Claude Code."}
        </div>
        {message ? <div class="callout secondary help-message">{message}</div> : null}
      </div>
      <SourceFoldersCard />
      <CloudSessionsCard />
    </div>
  );
}

/** Shortens a path under the home folder to ~\... */
export function tildePath(path: string): string {
  const home = store.homeDir.replace(/[\\/]+$/, "");
  if (home && path.toLowerCase().startsWith(home.toLowerCase())) return "~" + path.slice(home.length);
  return path;
}

export function sourceStatus(source: SourceStat, now: number): string {
  if (!source.exists) return "папки нет";
  if (source.files === 0) return "логов нет";
  let text = Fmt.plural(source.files, "лог", "лога", "логов");
  if (source.newestModification !== undefined) {
    text += ` · последний изменён ${Fmt.dateTime(source.newestModification)}, ${Fmt.ago((now - source.newestModification) / 1000)}`;
  }
  return text;
}

/** The folders X-Ray reads and what each one holds. */
export function SourceFoldersCard() {
  const s = useStore();
  const sources = s.scan?.sources ?? [];
  return (
    <Card title="Где X-Ray ищет логи" subtitle="транскрипты сессий, *.jsonl">
      <div class="stack-10">
        {sources.map((source) => (
          <div class="row gap-10" key={source.directory}>
            <Icon icon={source.exists ? I.Folder : I.FolderSearch} size={18} color={source.exists ? C.accent : "var(--text3)"} />
            <div class="stack-2 grow min0">
              <div class="mono callout selectable ellipsis" title={source.directory}>{tildePath(source.directory)}</div>
              <div class="caption secondary">{sourceStatus(source, s.now)}</div>
            </div>
            {source.exists ? <Button small onClick={() => void s.bridge.openPath(source.directory)}>Показать в проводнике</Button> : null}
          </div>
        ))}
        <hr />
        <div class="row gap-8">
          <Button small onClick={() => openSettings("sources")}>Изменить папки…</Button>
          <Button small onClick={() => void s.bridge.importDialog()}>Импортировать лог…</Button>
          <Button small onClick={() => void s.bridge.fullRescan()}>Пересканировать</Button>
        </div>
      </div>
    </Card>
  );
}

const WAYS: [LucideIcon, string][] = [
  [I.Terminal, "**Терминал:** `claude` в папке проекта (PowerShell, Windows Terminal или WSL с папкой логов из «Настройки → Источники»)."],
  [I.AppWindow, "**Claude Desktop:** сессия Code в локальной среде, а не в облачной."],
  [I.RadioTower, "**Remote Control:** `claude remote-control` в папке проекта. Сессия идёт на этом компьютере, управлять ею можно из приложения Claude на телефоне или в браузере, а X-Ray показывает её вживую."],
  [I.CloudDownload, "**Облачные сессии вживую:** «Настройки → Облако». Каждая облачная сессия сама присылает сюда свой лог после каждого шага через туннель к этому компьютеру."],
  [I.Download, "**Разово:** попросите облачную сессию прислать свой лог («пришли лог сессии для X-Ray») и перетащите файл в окно X-Ray."],
  [I.Gauge, "**Лимиты всего аккаунта**, включая облако и чаты, X-Ray берёт из строки статуса Claude Code: «Настройки → Лимиты аккаунта»."],
];

/** Why cloud sessions are missing, and how to run Claude Code so that X-Ray sees it live. */
export function CloudSessionsCard() {
  return (
    <Card title="Облачные сессии сюда сами не попадают">
      <div class="stack-10 callout">
        <div>
          Сессии Claude Code в облаке (claude.ai/code, мобильное приложение Claude, облачная среда в Claude Desktop) выполняются на серверах Anthropic, и их логи остаются там. Без настройки X-Ray видит только сессии, которые идут на этом компьютере:
        </div>
        {WAYS.map(([icon, text]) => (
          <div class="row top gap-10" key={text}>
            <Icon icon={icon} size={16} color={C.accent} />
            <span><Md text={text} /></span>
          </div>
        ))}
      </div>
    </Card>
  );
}
