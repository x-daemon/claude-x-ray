// Context window: fill, composition, per-request split, what inflates it, environment and permissions.
// Port of Views/Trace/TraceContextView.swift.
import { useMemo } from "preact/hooks";
import { Snippet } from "../../core/activity";
import { Fmt } from "../../core/fmt";
import { cacheHitRate, cacheWrite, contextTokens, contextWindow, displayModelName } from "../../core/model";
import type { PricedEvent } from "../../core/pricing";
import { knownComponents, traceGitBranch, traceProjectPath, type ContextSnapshot, type SessionTrace } from "../../core/trace";
import { axis, axisTooltip, baseOption, EChart, stackedBars, tokenAxisLabel, tooltipHTML, type ChartOption } from "../chart";
import * as I from "../icons";
import { store } from "../state";
import { C } from "../traceStyle";
import { Card, Chip, Chips, Icon, KeyValues, Legend, StatTile, Table, Tiles, UsageBar } from "../ui";
import { toolLabel } from "./traceParts";

export function TraceContextView({ trace, usage }: { trace: SessionTrace; usage: Map<string, PricedEvent> }) {
  const events = [...usage.values()].sort((a, b) => a.event.timestamp - b.event.timestamp);
  const main = events.filter((e) => !e.event.isSidechain);
  const last = main[main.length - 1] ?? events[events.length - 1];
  const window = last ? contextWindow(last.event.model) : 1_000_000;
  const now = last ? contextTokens(last.event.tokens) : 0;
  const ratio = now / Math.max(window, 1);
  const snapshot = trace.context;
  const modelCaption = [snapshot.modelID ?? last?.event.model, snapshot.knowledgeCutoff ? `знания до ${snapshot.knowledgeCutoff}` : undefined].filter(Boolean).join(" · ");

  return (
    <div class="page">
      <Tiles>
        <StatTile title="Контекст сейчас" value={Fmt.tokens(now)} caption={`${Fmt.percent(ratio)} окна ${Fmt.tokens(window)}`} icon={I.Gauge} />
        <StatTile title="Модель" value={snapshot.modelName ?? (last ? displayModelName(last.event.model) : "—")} caption={modelCaption} icon={I.Cpu} />
        <StatTile title="Effort" value={last?.event.effort ?? "—"} caption="глубина размышлений" icon={I.SlidersHorizontal} />
        <StatTile title="Кэш последнего запроса" value={last ? Fmt.percent(cacheHitRate(last.event.tokens)) : "—"} caption={(last?.event.tokens.cacheWrite1h ?? 0) > 0 ? "запись с TTL 1 ч" : "TTL 5 мин"} icon={I.MemoryStick} />
        <StatTile title="Сжатий контекста" value={String(snapshot.compactions)} caption="/compact и автоматические" icon={I.Minimize2} />
      </Tiles>

      <Card title="Заполнение окна контекста" subtitle={`${Fmt.tokens(now)} из ${Fmt.tokens(window)}`}>
        <UsageBar fraction={ratio} color={ratio >= 0.8 ? C.critical : ratio >= 0.6 ? C.warning : C.model} />
        <div class="caption secondary">
          {ratio >= 0.6
            ? `Контекст заполнен больше чем на ${Fmt.percent(ratio)}. Каждый следующий ход отправляет его целиком; подумайте о /compact или новой сессии.`
            : "Каждый ход заново отправляет весь контекст; чем он меньше, тем дешевле и быстрее ответы."}
        </div>
      </Card>

      <Card title="Из чего состоит контекст" subtitle="оценка ≈ 4 символа на токен">
        <Composition snapshot={snapshot} total={now} />
      </Card>

      <Card title="Контекст по запросам" subtitle="последние 80 запросов: чтение кэша, запись в кэш, свежий ввод">
        <ContextSplitChart events={main.slice(-80)} />
      </Card>

      <Card title="Что сильнее всего раздувает контекст" subtitle="самые большие результаты инструментов">
        <BiggestResults trace={trace} />
      </Card>

      <div class="row top gap-16 wrap-narrow">
        <Card title="Окружение" class="grow"><EnvironmentGrid snapshot={snapshot} trace={trace} /></Card>
        <Card title="Разрешения" class="grow"><Permissions trace={trace} /></Card>
      </div>

      {snapshot.editedFiles.length ? (
        <Card title="Файлы, изменённые вне Claude" subtitle="Claude получает об этом уведомление в контексте">
          <div class="stack-3">
            {snapshot.editedFiles.map((path) => <div key={path} class="mono caption selectable">{path}</div>)}
          </div>
        </Card>
      ) : null}
    </div>
  );
}

/** Known parts (system prompt, listings) vs the rest (conversation, tool results, tool schemas). */
function Composition({ snapshot, total }: { snapshot: ContextSnapshot; total: number }) {
  const known = knownComponents(snapshot);
  const knownTotal = known.reduce((a, k) => a + k.tokens, 0);
  const parts = [...known, ...(total > knownTotal ? [{ name: "Диалог, результаты инструментов, схемы", tokens: total - knownTotal }] : [])];
  const series = store.palette.series;
  const colors = parts.map((_, i) => (i < known.length ? series[i % series.length] : store.palette.other));
  const sum = parts.reduce((a, x) => a + x.tokens, 0);
  return (
    <div class="stack-10">
      {parts.length === 0 ? <div class="secondary">В транскрипте пока нет сведений о составе контекста</div> : (
        <>
          <div class="segbar" role="img" aria-label="Состав контекста">
            {parts.map((part, i) => (
              <span key={part.name} style={{ flexGrow: part.tokens, background: colors[i] }} title={`${part.name}: ≈${Fmt.tokens(part.tokens)}`} />
            ))}
          </div>
          <div class="segbar-scale caption2 secondary num">
            <span>0</span><span>{Fmt.tokens(Math.round(sum / 2))}</span><span>{Fmt.tokens(sum)}</span>
          </div>
          <div class="grid-4">
            {parts.map((part, i) => (
              <>
                <span class="swatch" style={{ background: colors[i] }} />
                <span>{part.name}</span>
                <span class="num">≈{Fmt.tokens(part.tokens)}</span>
                <span class="num secondary">{total > 0 ? Fmt.percent(part.tokens / total) : "—"}</span>
              </>
            ))}
          </div>
        </>
      )}
      <div class="caption secondary">
        Скиллов в контексте: {snapshot.skills.length} · отложенных инструментов: {snapshot.deferredTools.length} · типов субагентов: {snapshot.subagentTypes.length} · MCP с инструкциями: {snapshot.mcpWithInstructions.length}
      </div>
    </div>
  );
}

const SPLIT = ["Чтение кэша", "Запись в кэш", "Свежий ввод"] as const;

/** Stacked bars per request: cache read, cache write, fresh input. */
function ContextSplitChart({ events }: { events: PricedEvent[] }) {
  const p = store.palette;
  const colors = [p.series[2], p.series[3], p.series[0]];
  const option = useMemo<ChartOption>(() => ({
    ...baseOption(p),
    tooltip: axisTooltip(p, (i) => {
      const e = events[i].event;
      return tooltipHTML(`Запрос ${i + 1} · ${Fmt.time(e.timestamp)}`, [
        { label: SPLIT[0], value: Fmt.tokens(e.tokens.cacheRead), color: colors[0] },
        { label: SPLIT[1], value: Fmt.tokens(cacheWrite(e.tokens)), color: colors[1] },
        { label: SPLIT[2], value: Fmt.tokens(e.tokens.input), color: colors[2] },
      ]);
    }),
    xAxis: { type: "category", data: events.map((_, i) => String(i + 1)), ...axis(p, false) },
    yAxis: { type: "value", ...axis(p), axisLabel: { ...axis(p).axisLabel, formatter: tokenAxisLabel } },
    series: stackedBars(p, [
      { name: SPLIT[0], color: colors[0], values: events.map((e) => e.event.tokens.cacheRead) },
      { name: SPLIT[1], color: colors[1], values: events.map((e) => cacheWrite(e.event.tokens)) },
      { name: SPLIT[2], color: colors[2], values: events.map((e) => e.event.tokens.input) },
    ]),
  }), [events.length, events[events.length - 1]?.event.messageID, p]);
  if (!events.length) return <div class="secondary">Нет запросов</div>;
  return (
    <div>
      <EChart option={option} height={190} label="Контекст по запросам" />
      <Legend items={SPLIT.map((name, i) => ({ name, color: colors[i] }))} />
    </div>
  );
}

/** Largest tool outputs: each one stays in the context for the rest of the session. */
function BiggestResults({ trace }: { trace: SessionTrace }) {
  const biggest = trace.tools
    .filter((t) => (t.result?.outputBytes ?? 0) > 0)
    .sort((a, b) => (b.result?.outputBytes ?? 0) - (a.result?.outputBytes ?? 0))
    .slice(0, 10);
  if (!biggest.length) return <div class="secondary">Результатов инструментов пока нет</div>;
  return (
    <div class="stack-8">
      <Table
        head={["Инструмент", "Что", "Размер", "≈ токенов", "Когда"]}
        numeric={[2, 3]}
        keys={biggest.map((t) => t.call.id)}
        rows={biggest.map((tool) => {
          const bytes = tool.result?.outputBytes ?? 0;
          return [
            toolLabel(tool),
            <span class="mono caption ellipsis block">{Snippet.truncate(tool.call.title, 70)}</span>,
            Fmt.bytes(bytes),
            Fmt.tokens(Math.floor(bytes / 4)),
            <span class="secondary">{Fmt.time(tool.call.timestamp, false)}</span>,
          ];
        })}
      />
      <div class="caption secondary">
        Большие выводы (чтение целых файлов, длинные логи) остаются в контексте до /compact или конца сессии. Читайте файлы частями и фильтруйте вывод команд.
      </div>
    </div>
  );
}

function EnvironmentGrid({ snapshot, trace }: { snapshot: ContextSnapshot; trace: SessionTrace }) {
  const env = snapshot.environment;
  const dash = (v?: string) => (v && v.length ? v : "—");
  const rows: [string, string][] = [
    ["Рабочая папка", env.workingDirectory ?? traceProjectPath(trace) ?? "—"],
    ["Ветка git", traceGitBranch(trace) ?? "—"],
    ["Git-репозиторий", env.isGitRepo ?? "—"],
    ["Worktree", env.isWorktree ?? "—"],
    ["Платформа", [env.platform, env.osVersion].filter(Boolean).join(" · ")],
    ["Оболочка", env.shell ?? "—"],
    ["Доп. папки", env.additionalWorkingDirectories || "—"],
    ["Задач в списке", snapshot.taskCount !== undefined ? String(snapshot.taskCount) : "—"],
    ["Последнее изменение", snapshot.lastRemoteChange ?? "—"],
  ];
  return <KeyValues rows={rows.map(([k, v]) => [k, <span class="selectable clamp2">{dash(v)}</span>])} />;
}

function Permissions({ trace }: { trace: SessionTrace }) {
  const flags = trace.context.autoMode;
  return (
    <div class="stack-8">
      {trace.permissions.length === 0 ? <div class="secondary">Решений о разрешениях в логе нет</div> : (
        <>
          <div class="caption strong secondary">Как разрешались вызовы инструментов</div>
          {trace.permissions.map((permission) => (
            <div class="row gap-8 callout" key={permission.label}>
              <Icon icon={permission.label.startsWith("accept") ? I.ShieldCheck : I.Hand} size={15} color={C.model} />
              <span>{permission.label}</span>
              <span class="spacer" />
              <span class="num">{permission.count}</span>
            </div>
          ))}
        </>
      )}
      {flags ? (
        <>
          <hr />
          <div class="caption strong secondary">Auto mode</div>
          <Chips>{Object.keys(flags).sort().map((key) => <Chip key={key} text={`${key}: ${flags[key] ?? ""}`} tint={C.other} />)}</Chips>
        </>
      ) : null}
      {trace.context.allowedRules.length ? (
        <>
          <hr />
          <div class="caption strong secondary">Разрешённые правила</div>
          {trace.context.allowedRules.map((rule) => <div key={rule} class="mono caption selectable">{rule}</div>)}
        </>
      ) : null}
    </div>
  );
}
