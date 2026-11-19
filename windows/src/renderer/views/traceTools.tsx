// Tools, MCP servers (connectors), skills, subagents and files touched in the session.
// Port of Views/Trace/TraceToolsView.swift.
import { Snippet, toolDisplayName } from "../../core/activity";
import { Fmt } from "../../core/fmt";
import { mcpStatusTitle, statAverage, toolIsError, toolIsRunning, type FileTouch, type MCPServerUsage, type SessionTrace, type SkillUsage, type SubagentUsage, type ToolStat } from "../../core/trace";
import * as I from "../icons";
import { C, categoryIcon, mcpColor, mcpIcon } from "../traceStyle";
import { Card, Chip, Chips, Icon, Legend, RankedBarList, StatTile, Table, Tiles } from "../ui";
import { L, tr } from "../../core/i18n";

export function TraceToolsView({ trace }: { trace: SessionTrace }) {
  const connected = trace.mcpServers.filter((s) => s.status === "connected").length;
  const invokedSkills = trace.skills.filter((s) => s.invocations > 0).length;
  const agentRuns = trace.subagents.reduce((a, s) => a + s.calls, 0);
  return (
    <div class="page">
      <Tiles>
        <StatTile title={L`Вызовов инструментов`} value={String(trace.tools.length)} caption={L`ошибок ${trace.tools.filter(toolIsError).length}, сейчас ${trace.tools.filter(toolIsRunning).length}`} icon={I.Wrench} />
        <StatTile title={L`MCP-серверы`} value={String(trace.mcpServers.length)} caption={L`подключено ${connected}, вызывались ${trace.mcpServers.filter((s) => s.calls > 0).length}`} icon={I.Puzzle} />
        <StatTile title={L`Скиллы`} value={`${invokedSkills} / ${trace.skills.length}`} caption={L`вызваны / доступны`} icon={I.Sparkles} />
        <StatTile title={L`Субагенты`} value={String(agentRuns)} caption={L`запусков, типов ${trace.subagents.length}`} icon={I.Users} />
        <StatTile title={L`Файлы`} value={String(trace.files.length)} caption={L`прочитано, записано, изменено`} icon={I.Files} />
      </Tiles>

      <Card title={L`Инструменты`} subtitle={L`число вызовов, ошибки, время работы и объём вывода`}>
        <ToolStatsChart stats={trace.toolStats.slice(0, 15)} />
        {trace.toolStats.length ? <ToolStatsTable stats={trace.toolStats} /> : null}
      </Card>

      <Card title={L`MCP-серверы и коннекторы`} subtitle={L`из списка инструментов сессии и фактических вызовов`}>
        <MCPServers servers={trace.mcpServers} />
      </Card>

      <div class="row top gap-16 wrap-narrow">
        <Card title={L`Скиллы`} subtitle={L`подсвечены вызванные`} class="grow"><Skills skills={trace.skills} /></Card>
        <Card title={L`Субагенты`} style={{ flex: "0 1 420px" }}><Subagents agents={trace.subagents} /></Card>
      </div>

      <Card title={L`Файлы`} subtitle={L`последние 60 по времени обращения`}>
        <FilesTable files={trace.files.slice(0, 60)} />
      </Card>
    </div>
  );
}

function ToolStatsChart({ stats }: { stats: ToolStat[] }) {
  if (!stats.length) return <div class="secondary">{L`Инструменты ещё не вызывались`}</div>;
  return (
    <div class="stack-8">
      <RankedBarList rows={stats.map((stat) => {
        const ok = stat.calls - stat.errors - stat.running;
        return {
          id: stat.name,
          label: toolDisplayName(stat.name),
          detail: tr(stat.category),
          value: stat.calls,
          valueText: L`${stat.calls} · ср. ${Fmt.shortDuration(statAverage(stat))}`,
          segments: [
            { value: ok, color: C.tool },
            { value: stat.errors, color: C.critical },
            { value: stat.running, color: C.warning },
          ].filter((s) => s.value > 0),
          help: L`успешно ${ok}, ошибок ${stat.errors}, выполняется ${stat.running}`,
        };
      })} />
      <Legend items={[{ name: L`успех`, color: C.tool }, { name: L`ошибка`, color: C.critical }, { name: L`выполняется`, color: C.warning }]} />
    </div>
  );
}

function ToolStatsTable({ stats }: { stats: ToolStat[] }) {
  return (
    <Table
      head={[L`Инструмент`, L`Категория`, L`Вызовы`, L`Ошибки`, L`Среднее`, L`Максимум`, L`Всего`, L`Генерация ввода`, L`Вывод`]}
      numeric={[2, 3, 4, 5, 6, 7, 8]}
      keys={stats.map((s) => s.name)}
      rows={stats.map((stat) => [
        <span class="row gap-6 nowrap"><Icon icon={categoryIcon[stat.category]} size={14} class="secondary" /><span class="ellipsis">{toolDisplayName(stat.name)}</span></span>,
        <span class="secondary">{tr(stat.category)}</span>,
        `${stat.calls}` + (stat.running > 0 ? L` (${stat.running} идёт)` : ""),
        <span class={stat.errors > 0 ? "critical" : ""}>{stat.errors}</span>,
        Fmt.shortDuration(statAverage(stat)),
        Fmt.shortDuration(stat.maxDuration),
        Fmt.shortDuration(stat.totalDuration),
        stat.inputStreamMs > 0 ? Fmt.ms(stat.inputStreamMs) : "—",
        stat.outputBytes > 0 ? Fmt.bytes(stat.outputBytes) : "—",
      ])}
    />
  );
}

function MCPServers({ servers }: { servers: MCPServerUsage[] }) {
  if (!servers.length) return <div class="secondary">{L`MCP-серверы в этой сессии не встречались`}</div>;
  return (
    <div class="stack-10">
      {servers.map((server) => (
        <div class="stack-5 divided" key={server.name}>
          <div class="row baseline gap-8 wrap">
            <Icon icon={I.Puzzle} size={15} color={C.mcp} />
            <span class="callout strong">{server.name}</span>
            <Chip text={mcpStatusTitle[server.status]} icon={mcpIcon[server.status]} tint={mcpColor[server.status]} />
            {server.hasInstructions ? <Chip text={L`есть инструкции`} icon={I.BookOpen} tint={C.other} /> : null}
            <span class="spacer" />
            <span class="caption num secondary">
              {L`инструментов ${server.toolsAvailable} · вызовов ${server.calls} · ошибок ${server.errors} · ${Fmt.shortDuration(server.totalDuration)}`}
            </span>
          </div>
          {Object.keys(server.tools).length ? (
            <Chips indent={24}>
              {Object.entries(server.tools).sort((a, b) => b[1] - a[1]).map(([tool, count]) => <Chip key={tool} text={`${tool} × ${count}`} tint={C.mcp} />)}
            </Chips>
          ) : null}
        </div>
      ))}
    </div>
  );
}

function Skills({ skills }: { skills: SkillUsage[] }) {
  if (!skills.length) return <div class="secondary">{L`Список скиллов в логе не найден`}</div>;
  return (
    <Chips>
      {skills.map((skill) => (
        <Chip
          key={skill.name}
          text={skill.invocations > 0 ? `${skill.name} × ${skill.invocations}` : skill.name}
          icon={skill.invocations > 0 ? I.Sparkles : undefined}
          tint={skill.invocations > 0 ? C.skill : C.other}
          title={skill.lastUsed !== undefined ? L`последний вызов ${Fmt.time(skill.lastUsed)}` : skill.available ? L`доступен, не вызывался` : L`вызван, но не в списке`}
        />
      ))}
    </Chips>
  );
}

function Subagents({ agents }: { agents: SubagentUsage[] }) {
  if (!agents.length) return <div class="secondary">{L`Субагенты не встречались`}</div>;
  return (
    <div class="stack-5">
      {agents.map((agent) => (
        <div class="row gap-12 callout" key={agent.type}>
          <Icon icon={I.Users} size={15} color={agent.calls > 0 ? C.subagent : C.other} />
          <span>{agent.type}</span>
          <span class="secondary">{agent.calls > 0 ? L`${agent.calls} запуск. · ${Fmt.shortDuration(agent.totalDuration)}` : L`доступен`}</span>
          <span class="spacer" />
          {agent.running > 0 ? <Chip text={L`работает`} icon={I.Hourglass} tint={C.warning} />
            : agent.errors > 0 ? <Chip text={L`ошибок ${agent.errors}`} icon={I.CircleX} tint={C.critical} /> : null}
        </div>
      ))}
    </div>
  );
}

function FilesTable({ files }: { files: FileTouch[] }) {
  if (!files.length) return <div class="secondary">{L`Файлы не читались и не менялись`}</div>;
  return (
    <Table
      head={[L`Файл`, L`Чтение`, L`Запись`, L`Правки`, L`Строки`, L`Ошибки`, L`Последнее`]}
      numeric={[1, 2, 3, 4, 5]}
      keys={files.map((f) => f.path)}
      rows={files.map((file) => [
        <span class="mono callout ellipsis block" title={file.path}>{Snippet.shortPath(file.path)}</span>,
        file.reads > 0 ? String(file.reads) : "—",
        file.writes > 0 ? String(file.writes) : "—",
        file.edits > 0 ? String(file.edits) : "—",
        file.linesAdded + file.linesRemoved > 0 ? `+${file.linesAdded} −${file.linesRemoved}` : "—",
        <span class={file.errors > 0 ? "critical" : "secondary"}>{file.errors > 0 ? file.errors : "—"}</span>,
        <span class="secondary">{Fmt.time(file.last)}</span>,
      ])}
    />
  );
}
