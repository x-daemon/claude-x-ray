// Activity store, session trace model and builder.
// Port of XRayCore/Activity/{ActivityStore,Trace,TraceBuilder}.swift. Times are epoch ms.
import { mcpServer, mcpTool, toolCategory, type ActivityItem, type ToolCategory } from "./activity";
import { projectName } from "./model";
import { L, labels, N } from "./i18n";

// MARK: Store

/** A session seen in the activity trace, for the session picker. */
export interface SessionActivity {
  id: string;
  projectPath: string;
  gitBranch?: string;
  firstActivity: number;
  lastActivity: number;
  items: number;
  toolCalls: number;
  errors: number;
  lastTitle: string;
}

export const sessionActivityProject = (s: SessionActivity): string => projectName(s.projectPath);

/** Recent activity items, de-duplicated and time-ordered, with bounded retention. */
export class ActivityStore {
  items: ActivityItem[] = [];
  private ids = new Set<string>();

  constructor(public retention = 3 * 86_400_000, public capacity = 40_000) {}

  get count(): number {
    return this.items.length;
  }

  /** Adds new items. Returns how many were new. */
  merge(newItems: ActivityItem[], now = Date.now()): number {
    let added = 0;
    let needsSort = false;
    const cutoff = now - this.retention;
    for (const item of newItems) {
      if (item.timestamp < cutoff || this.ids.has(item.id)) continue;
      this.ids.add(item.id);
      const last = this.items[this.items.length - 1];
      if (last && item.timestamp < last.timestamp) needsSort = true;
      this.items.push(item);
      added++;
    }
    if (needsSort) {
      // Stable for equal timestamps: blocks of one response keep their order (Array.sort is stable).
      this.items.sort((a, b) => a.timestamp - b.timestamp);
    }
    if (this.items.length > this.capacity) this.drop(this.items.length - this.capacity);
    return added;
  }

  /** Drops items older than the retention period. */
  prune(now = Date.now()): void {
    const cutoff = now - this.retention;
    let stale = 0;
    while (stale < this.items.length && this.items[stale].timestamp < cutoff) stale++;
    if (stale > 0) this.drop(stale);
  }

  removeAll(): void {
    this.items = [];
    this.ids.clear();
  }

  private drop(count: number): void {
    for (const item of this.items.slice(0, count)) this.ids.delete(item.id);
    this.items.splice(0, count);
  }

  itemsForSession(id: string): ActivityItem[] {
    return this.items.filter((i) => i.sessionID === id);
  }

  /** Sessions with activity, most recently active first. */
  sessions(): SessionActivity[] {
    const byID = new Map<string, SessionActivity>();
    for (const item of this.items) {
      const s = byID.get(item.sessionID);
      if (s) {
        s.lastActivity = Math.max(s.lastActivity, item.timestamp);
        s.firstActivity = Math.min(s.firstActivity, item.timestamp);
        s.items++;
        if (item.kind === "toolCall") s.toolCalls++;
        if (item.isError) s.errors++;
        if (item.kind !== "context") s.lastTitle = item.title;
        s.gitBranch ??= item.gitBranch;
        if (s.projectPath === "unknown") s.projectPath = item.projectPath;
      } else {
        byID.set(item.sessionID, {
          id: item.sessionID,
          projectPath: item.projectPath,
          gitBranch: item.gitBranch,
          firstActivity: item.timestamp,
          lastActivity: item.timestamp,
          items: 1,
          toolCalls: item.kind === "toolCall" ? 1 : 0,
          errors: item.isError ? 1 : 0,
          lastTitle: item.title,
        });
      }
    }
    return [...byID.values()].sort((a, b) => b.lastActivity - a.lastActivity);
  }
}

// MARK: Trace model

export interface ToolExecution {
  call: ActivityItem;
  result?: ActivityItem;
}

export const toolName = (t: ToolExecution): string => t.call.toolName ?? "tool";
export const toolCat = (t: ToolExecution): ToolCategory => toolCategory(toolName(t));
export const toolIsRunning = (t: ToolExecution): boolean => !t.result;
export const toolIsError = (t: ToolExecution): boolean => t.result?.isError ?? false;
export const toolMcpServer = (t: ToolExecution): string | undefined => mcpServer(toolName(t));
/** Seconds. */
export const toolDuration = (t: ToolExecution, now: number): number => Math.max(0, ((t.result?.timestamp ?? now) - t.call.timestamp) / 1000);

export interface ModelStep {
  messageID: string;
  model?: string;
  requestedModel?: string;
  effort?: string;
  start: number;
  end: number;
  thinkingMs: number;
  inputStreamMs: number;
  toolCallIDs: string[];
  replyText?: string;
  stopReason?: string;
  isSidechain: boolean;
  attributionSkill?: string;
}

/** Seconds. */
export const stepDuration = (s: ModelStep): number => Math.max(0, (s.end - s.start) / 1000);

export type FlowNode =
  | { type: "step"; step: ModelStep; children: FlowNode[] }
  | { type: "tool"; tool: ToolExecution }
  | { type: "item"; item: ActivityItem };

export function flowNodeID(node: FlowNode): string {
  switch (node.type) {
    // A response interleaved with subagent blocks can appear twice in a turn.
    case "step": return `step|${node.step.messageID}|${node.children[0] ? flowNodeID(node.children[0]) : ""}`;
    case "tool": return `tool|${node.tool.call.id}`;
    case "item": return `item|${node.item.id}`;
  }
}

export type TurnOutcome = "inProgress" | "completed" | "interrupted" | "failed";

export interface TraceTurn {
  id: string;
  index: number;
  prompt?: ActivityItem;
  start: number;
  end: number;
  nodes: FlowNode[];
  stepIDs: string[];
  toolCalls: number;
  errors: number;
  outcome: TurnOutcome;
}

export interface FileTouch {
  path: string;
  reads: number;
  writes: number;
  edits: number;
  errors: number;
  linesAdded: number;
  linesRemoved: number;
  last: number;
}

export interface ToolStat {
  name: string;
  category: ToolCategory;
  calls: number;
  errors: number;
  running: number;
  /** Seconds. */
  totalDuration: number;
  maxDuration: number;
  inputStreamMs: number;
  outputBytes: number;
}

export const statAverage = (s: ToolStat): number => {
  const completed = s.calls - s.running;
  return completed > 0 ? s.totalDuration / completed : 0;
};

export type MCPStatus = "connected" | "pending" | "failed" | "needsAuth" | "usedOnly";
export const mcpStatusTitle: Record<MCPStatus, string> = labels({
  connected: N("Подключён"),
  pending: N("Подключается"),
  failed: N("Ошибка подключения"),
  needsAuth: N("Нужна авторизация"),
  usedOnly: N("Вызывался"),
});

export interface MCPServerUsage {
  name: string;
  status: MCPStatus;
  toolsAvailable: number;
  hasInstructions: boolean;
  calls: number;
  errors: number;
  totalDuration: number;
  tools: Record<string, number>;
}

export interface SkillUsage {
  name: string;
  available: boolean;
  invocations: number;
  attributedSteps: number;
  lastUsed?: number;
}

export interface SubagentUsage {
  type: string;
  available: boolean;
  calls: number;
  running: number;
  errors: number;
  totalDuration: number;
}

export interface ContextSnapshot {
  modelID?: string;
  modelName?: string;
  knowledgeCutoff?: string;
  systemPromptChars?: number;
  skillListingChars: number;
  mcpInstructionChars: number;
  agentListingChars: number;
  toolListingChars: number;
  deferredTools: string[];
  skills: string[];
  subagentTypes: string[];
  mcpWithInstructions: string[];
  pendingMCP: string[];
  failedMCP: string[];
  needsAuthMCP: string[];
  environment: Record<string, string>;
  autoMode?: Record<string, string>;
  allowedRules: string[];
  editedFiles: string[];
  taskCount?: number;
  compactions: number;
  lastRemoteChange?: string;
}

const emptyContext = (): ContextSnapshot => ({
  skillListingChars: 0, mcpInstructionChars: 0, agentListingChars: 0, toolListingChars: 0,
  deferredTools: [], skills: [], subagentTypes: [], mcpWithInstructions: [], pendingMCP: [], failedMCP: [], needsAuthMCP: [],
  environment: {}, allowedRules: [], editedFiles: [], compactions: 0,
});

export const estimatedTokens = (chars: number): number => Math.floor(chars / 4);

/** Known pieces of the context with estimated token counts (chars / 4). */
export function knownComponents(c: ContextSnapshot): { name: string; tokens: number }[] {
  return [
    { name: L`Системный промпт`, tokens: estimatedTokens(c.systemPromptChars ?? 0) },
    { name: L`Список скиллов`, tokens: estimatedTokens(c.skillListingChars) },
    { name: L`Инструкции MCP`, tokens: estimatedTokens(c.mcpInstructionChars) },
    { name: L`Типы субагентов`, tokens: estimatedTokens(c.agentListingChars) },
    { name: L`Список отложенных инструментов`, tokens: estimatedTokens(c.toolListingChars) },
  ].filter((x) => x.tokens > 0);
}

export interface PermissionStat {
  label: string;
  count: number;
}

export interface FlowTransition {
  from: string;
  to: string;
  count: number;
}

export type LiveState =
  | { type: "runningTool"; name: string; title: string }
  | { type: "runningSubagent"; title: string }
  | { type: "thinking" }
  | { type: "writing" }
  | { type: "waitingForUser" }
  /** Thinking or writing, but nothing new has reached the log for minutes: the model may still be
   * answering, or a cloud session's next lines have not arrived yet. */
  | { type: "quiet" }
  | { type: "interrupted" }
  | { type: "error"; message: string }
  | { type: "idle" };

export const stateIsActive = (s: LiveState): boolean =>
  s.type === "runningTool" || s.type === "runningSubagent" || s.type === "thinking" || s.type === "writing";

export function stateTitle(s: LiveState): string {
  switch (s.type) {
    case "runningTool": return L`Выполняет ${s.name}`;
    case "runningSubagent": return L`Работает субагент`;
    case "thinking": return L`Думает`;
    case "writing": return L`Пишет ответ`;
    case "waitingForUser": return L`Ждёт вас`;
    case "quiet": return L`Нет новых событий`;
    case "interrupted": return L`Прервано`;
    case "error": return L`Ошибка`;
    case "idle": return L`Нет активности`;
  }
}

export function stateDetail(s: LiveState): string | undefined {
  switch (s.type) {
    case "runningTool": return s.title;
    case "runningSubagent": return s.title;
    case "error": return s.message;
    default: return undefined;
  }
}

export interface LiveStatus {
  state: LiveState;
  since: number;
  lastActivity: number;
  turnStart?: number;
  stepsInTurn: number;
  toolsInTurn: number;
  runningTools: number;
  sessionID: string;
}

export interface SessionTrace {
  sessionID: string;
  items: ActivityItem[];
  steps: ModelStep[];
  tools: ToolExecution[];
  turns: TraceTurn[];
  files: FileTouch[];
  toolStats: ToolStat[];
  mcpServers: MCPServerUsage[];
  skills: SkillUsage[];
  subagents: SubagentUsage[];
  context: ContextSnapshot;
  permissions: PermissionStat[];
  transitions: FlowTransition[];
  status?: LiveStatus;
  errors: number;
  prompts: number;
}

export const traceProjectPath = (t: SessionTrace): string | undefined => t.items.find((i) => i.projectPath !== "unknown")?.projectPath;
export const traceGitBranch = (t: SessionTrace): string | undefined => [...t.items].reverse().find((i) => i.gitBranch)?.gitBranch;

// MARK: Builder

/** No activity for this long counts as idle. */
export const DEFAULT_IDLE_AFTER = 10 * 60_000;
/** After this long without a new event, "thinking" or "writing" would only be a guess. */
export const QUIET_AFTER = 3 * 60_000;
/** A tool call without a result older than this is treated as abandoned. */
export const RUNNING_TOOL_TIMEOUT = 30 * 60_000;

export function buildTrace(sessionID: string, unsorted: ActivityItem[], now = Date.now(), idleAfter = DEFAULT_IDLE_AFTER): SessionTrace {
  const items = [...unsorted].sort((a, b) => a.timestamp - b.timestamp); // stable
  const tools = buildTools(items);
  const steps = buildSteps(items);
  const context = buildContext(items);
  return {
    sessionID,
    items,
    tools,
    steps,
    context,
    turns: buildTurns(items, tools, steps, now, idleAfter),
    files: buildFiles(tools),
    toolStats: buildToolStats(tools, now),
    mcpServers: buildMcpServers(tools, context, now),
    skills: buildSkills(tools, steps, context),
    subagents: buildSubagents(tools, context, now),
    permissions: buildPermissions(items),
    transitions: buildTransitions(items, tools),
    status: buildStatus(sessionID, items, tools, now, idleAfter),
    errors: items.filter((i) => i.isError).length,
    prompts: items.filter((i) => i.kind === "prompt" && !i.isSidechain).length,
  };
}

function buildTools(items: ActivityItem[]): ToolExecution[] {
  const results = new Map<string, ActivityItem>();
  for (const item of items) if (item.kind === "toolResult" && item.toolUseID) results.set(item.toolUseID, item);
  return items.filter((i) => i.kind === "toolCall").map((call) => ({ call, result: call.toolUseID ? results.get(call.toolUseID) : undefined }));
}

function buildSteps(items: ActivityItem[]): ModelStep[] {
  const order: string[] = [];
  const byID = new Map<string, ModelStep>();
  // The model starts working when its input arrives: a prompt, a tool result, a delivered message.
  const lastInput = new Map<boolean, number>();
  for (const item of items) {
    if (item.kind === "prompt" || item.kind === "queued" || item.kind === "compact" || (item.kind === "toolResult" && !item.messageID)) {
      lastInput.set(item.isSidechain, item.timestamp);
      continue;
    }
    const messageID = item.messageID;
    if (!messageID) continue;
    const existing = byID.get(messageID);
    if (existing) {
      existing.end = Math.max(existing.end, item.timestamp);
      absorb(item, existing);
    } else {
      let start = lastInput.get(item.isSidechain) ?? item.timestamp;
      if (start > item.timestamp) start = item.timestamp;
      const step: ModelStep = { messageID, start, end: item.timestamp, thinkingMs: 0, inputStreamMs: 0, toolCallIDs: [], isSidechain: item.isSidechain };
      absorb(item, step);
      byID.set(messageID, step);
      order.push(messageID);
    }
    // The next response starts after this one unless new input arrives.
    lastInput.set(item.isSidechain, item.timestamp);
  }
  return order.map((id) => byID.get(id)!);
}

function absorb(item: ActivityItem, step: ModelStep): void {
  step.model ??= item.model;
  step.requestedModel ??= item.requestedModel;
  step.effort ??= item.effort;
  step.attributionSkill ??= item.attributionSkill;
  if (item.stopReason) step.stopReason = item.stopReason;
  step.thinkingMs += item.thinkingMs ?? 0;
  step.inputStreamMs += item.inputStreamMs ?? 0;
  if (item.kind === "toolCall") step.toolCallIDs.push(item.id);
  if (item.kind === "reply") step.replyText = item.detail ?? item.title;
}

function buildTurns(items: ActivityItem[], tools: ToolExecution[], steps: ModelStep[], now: number, idleAfter: number): TraceTurn[] {
  const toolByCall = new Map<string, ToolExecution>();
  for (const t of tools) if (!toolByCall.has(t.call.id)) toolByCall.set(t.call.id, t);
  const stepByID = new Map<string, ModelStep>();
  for (const s of steps) if (!stepByID.has(s.messageID)) stepByID.set(s.messageID, s);

  // Split at user prompts of the main thread.
  const groups: ActivityItem[][] = [];
  for (const item of items) {
    if ((item.kind === "prompt" && !item.isSidechain) || groups.length === 0) groups.push([item]);
    else groups[groups.length - 1].push(item);
  }
  const lastActivity = items[items.length - 1]?.timestamp ?? now;

  return groups.map((group, index) => {
    const prompt = group.find((i) => i.kind === "prompt" && !i.isSidechain);
    const nodes: FlowNode[] = [];
    let open: { id: string; children: FlowNode[] } | undefined;
    const stepIDs: string[] = [];
    const closeStep = () => {
      if (open) {
        const step = stepByID.get(open.id);
        if (step) nodes.push({ type: "step", step, children: open.children });
      }
      open = undefined;
    };
    for (const item of group) {
      if (prompt && item.id === prompt.id) continue;
      if (item.messageID) {
        if (open?.id !== item.messageID) {
          closeStep();
          open = { id: item.messageID, children: [] };
          if (!stepIDs.includes(item.messageID)) stepIDs.push(item.messageID);
        }
        const tool = item.kind === "toolCall" ? toolByCall.get(item.id) : undefined;
        open!.children.push(tool ? { type: "tool", tool } : { type: "item", item });
        continue;
      }
      // A tool result is shown inside its tool call.
      if (item.kind === "toolResult") continue;
      closeStep();
      nodes.push({ type: "item", item });
    }
    closeStep();
    const last = group[group.length - 1];
    let outcome: TurnOutcome;
    if (group.some((i) => i.kind === "interrupted")) outcome = "interrupted";
    else if (last?.kind === "apiError") outcome = "failed";
    else if (index === groups.length - 1 && now - lastActivity < idleAfter && !(last?.kind === "reply" && last.stopReason === "end_turn")) outcome = "inProgress";
    else outcome = "completed";
    return {
      id: group[0]?.id ?? `turn-${index}`,
      index,
      prompt,
      start: group[0]?.timestamp ?? now,
      end: last?.timestamp ?? now,
      nodes,
      stepIDs,
      toolCalls: group.filter((i) => i.kind === "toolCall").length,
      errors: group.filter((i) => i.isError).length,
      outcome,
    };
  });
}

function buildFiles(tools: ToolExecution[]): FileTouch[] {
  const byPath = new Map<string, FileTouch>();
  for (const tool of tools) {
    const action = tool.call.fileAction;
    const path = tool.call.target;
    if (!action || !path) continue;
    let touch = byPath.get(path);
    if (!touch) byPath.set(path, (touch = { path, reads: 0, writes: 0, edits: 0, errors: 0, linesAdded: 0, linesRemoved: 0, last: tool.call.timestamp }));
    if (action === "read") touch.reads++;
    else if (action === "write") touch.writes++;
    else touch.edits++;
    if (toolIsError(tool)) touch.errors++;
    touch.linesAdded += tool.result?.linesAdded ?? 0;
    touch.linesRemoved += tool.result?.linesRemoved ?? 0;
    touch.last = Math.max(touch.last, tool.call.timestamp);
  }
  return [...byPath.values()].sort((a, b) => b.last - a.last);
}

function buildToolStats(tools: ToolExecution[], now: number): ToolStat[] {
  const byName = new Map<string, ToolStat>();
  for (const tool of tools) {
    const name = toolName(tool);
    let stat = byName.get(name);
    if (!stat) byName.set(name, (stat = { name, category: toolCat(tool), calls: 0, errors: 0, running: 0, totalDuration: 0, maxDuration: 0, inputStreamMs: 0, outputBytes: 0 }));
    stat.calls++;
    if (toolIsError(tool)) stat.errors++;
    if (toolIsRunning(tool)) stat.running++;
    else {
      const d = toolDuration(tool, now);
      stat.totalDuration += d;
      stat.maxDuration = Math.max(stat.maxDuration, d);
    }
    stat.inputStreamMs += tool.call.inputStreamMs ?? 0;
    stat.outputBytes += tool.result?.outputBytes ?? 0;
  }
  return [...byName.values()].sort((a, b) => (a.calls === b.calls ? (a.name < b.name ? -1 : 1) : b.calls - a.calls));
}

function buildContext(items: ActivityItem[]): ContextSnapshot {
  const snapshot = emptyContext();
  const deferred = new Set<string>();
  const skills = new Set<string>();
  const agents = new Set<string>();
  const instructions = new Set<string>();
  for (const item of items) {
    if (item.kind === "compact") snapshot.compactions++;
    const p = item.context;
    if (!p) continue;
    switch (p.type) {
      case "tools":
        p.added.forEach((n) => deferred.add(n));
        p.removed.forEach((n) => deferred.delete(n));
        snapshot.toolListingChars += p.listingChars;
        snapshot.pendingMCP = p.pendingMCP;
        snapshot.failedMCP = p.failedMCP;
        snapshot.needsAuthMCP = p.needsAuthMCP;
        break;
      case "skills":
        p.names.forEach((n) => skills.add(n));
        snapshot.skillListingChars = p.listingChars;
        break;
      case "mcpInstructions":
        p.added.forEach((n) => instructions.add(n));
        p.removed.forEach((n) => instructions.delete(n));
        snapshot.mcpInstructionChars += p.chars;
        break;
      case "agents":
        p.added.forEach((n) => agents.add(n));
        p.removed.forEach((n) => agents.delete(n));
        snapshot.agentListingChars += p.chars;
        break;
      case "systemPrompt":
        snapshot.systemPromptChars = p.chars;
        break;
      case "environment":
        Object.assign(snapshot.environment, p.values);
        break;
      case "model":
        snapshot.modelID = p.id;
        snapshot.modelName = p.name;
        snapshot.knowledgeCutoff = p.knowledgeCutoff;
        break;
      case "autoMode":
        snapshot.autoMode = p.values;
        break;
      case "permissions":
        snapshot.allowedRules = p.allowed;
        break;
      case "editedFile":
        if (!snapshot.editedFiles.includes(p.path)) snapshot.editedFiles.push(p.path);
        break;
      case "tasks":
        snapshot.taskCount = p.count;
        break;
      case "remoteChange":
        snapshot.lastRemoteChange = p.commit ?? p.pullRequest ?? p.url;
        break;
    }
  }
  snapshot.deferredTools = [...deferred].sort();
  snapshot.skills = [...skills].sort();
  snapshot.subagentTypes = [...agents].sort();
  snapshot.mcpWithInstructions = [...instructions].sort();
  return snapshot;
}

function buildMcpServers(tools: ToolExecution[], context: ContextSnapshot, now: number): MCPServerUsage[] {
  const servers = new Map<string, MCPServerUsage>();
  const get = (name: string, status: MCPStatus): MCPServerUsage => {
    let s = servers.get(name);
    if (!s) servers.set(name, (s = { name, status, toolsAvailable: 0, hasInstructions: false, calls: 0, errors: 0, totalDuration: 0, tools: {} }));
    return s;
  };
  for (const name of context.deferredTools) {
    const server = mcpServer(name);
    if (server) get(server, "connected").toolsAvailable++;
  }
  for (const name of context.mcpWithInstructions) get(name, "connected").hasInstructions = true;
  for (const tool of tools) {
    const server = toolMcpServer(tool);
    if (!server) continue;
    const usage = get(server, "usedOnly");
    usage.calls++;
    if (toolIsError(tool)) usage.errors++;
    usage.totalDuration += toolDuration(tool, now);
    const t = mcpTool(toolName(tool)) ?? toolName(tool);
    usage.tools[t] = (usage.tools[t] ?? 0) + 1;
  }
  for (const name of context.pendingMCP) get(name, "pending").status = "pending";
  for (const name of context.needsAuthMCP) get(name, "needsAuth").status = "needsAuth";
  for (const name of context.failedMCP) get(name, "failed").status = "failed";
  return [...servers.values()].sort((a, b) => (a.calls === b.calls ? (a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1) : b.calls - a.calls));
}

function buildSkills(tools: ToolExecution[], steps: ModelStep[], context: ContextSnapshot): SkillUsage[] {
  const skills = new Map<string, SkillUsage>();
  const get = (name: string): SkillUsage => {
    let s = skills.get(name);
    if (!s) skills.set(name, (s = { name, available: false, invocations: 0, attributedSteps: 0 }));
    return s;
  };
  for (const name of context.skills) get(name).available = true;
  for (const tool of tools) {
    if (toolName(tool) !== "Skill") continue;
    const usage = get(tool.call.target ?? "?");
    usage.invocations++;
    usage.lastUsed = Math.max(usage.lastUsed ?? tool.call.timestamp, tool.call.timestamp);
  }
  for (const step of steps) if (step.attributionSkill) get(step.attributionSkill).attributedSteps++;
  return [...skills.values()].sort((a, b) => (a.invocations !== b.invocations ? b.invocations - a.invocations : a.name < b.name ? -1 : 1));
}

function buildSubagents(tools: ToolExecution[], context: ContextSnapshot, now: number): SubagentUsage[] {
  const agents = new Map<string, SubagentUsage>();
  const get = (type: string): SubagentUsage => {
    let s = agents.get(type);
    if (!s) agents.set(type, (s = { type, available: false, calls: 0, running: 0, errors: 0, totalDuration: 0 }));
    return s;
  };
  for (const type of context.subagentTypes) get(type).available = true;
  for (const tool of tools) {
    if (toolCat(tool) !== "Субагенты" || toolName(tool) === "SendMessage") continue;
    const usage = get(tool.call.target ?? "general-purpose");
    usage.calls++;
    if (toolIsRunning(tool)) usage.running++;
    if (toolIsError(tool)) usage.errors++;
    usage.totalDuration += toolDuration(tool, now);
  }
  return [...agents.values()].sort((a, b) => (a.calls === b.calls ? (a.type < b.type ? -1 : 1) : b.calls - a.calls));
}

function buildPermissions(items: ActivityItem[]): PermissionStat[] {
  const counts = new Map<string, number>();
  for (const item of items) if (item.permission) counts.set(item.permission, (counts.get(item.permission) ?? 0) + 1);
  return [...counts.entries()].map(([label, count]) => ({ label, count })).sort((a, b) => b.count - a.count);
}

/** Node label used by the flow map. */
export function flowLabel(tool: ToolExecution): string {
  const server = toolMcpServer(tool);
  if (server) return `MCP: ${server}`;
  const category = toolCat(tool);
  if (category === "Субагенты") return L`Субагент`;
  if (category === "Скиллы") return L`Скилл`;
  return toolName(tool);
}

function buildTransitions(items: ActivityItem[], tools: ToolExecution[]): FlowTransition[] {
  const toolByCall = new Map<string, ToolExecution>();
  for (const t of tools) if (!toolByCall.has(t.call.id)) toolByCall.set(t.call.id, t);
  const sequence: string[] = [];
  let lastMessage: string | undefined;
  for (const item of items) {
    if (item.isSidechain) continue;
    switch (item.kind) {
      case "prompt": sequence.push(L`Промпт`); lastMessage = undefined; break;
      case "queued": if (item.title.startsWith(L`Передано модели: `)) sequence.push(L`Сообщение во время работы`); break;
      case "interrupted": sequence.push(L`Прерывание`); break;
      case "compact": sequence.push(L`Сжатие контекста`); break;
      case "apiError": sequence.push(L`Ошибка API`); break;
      case "thinking": case "reply": case "toolCall": {
        if (item.messageID && item.messageID !== lastMessage) {
          sequence.push(L`Модель`);
          lastMessage = item.messageID;
        }
        const tool = item.kind === "toolCall" ? toolByCall.get(item.id) : undefined;
        if (tool) {
          sequence.push(flowLabel(tool));
          if (toolIsError(tool)) sequence.push(L`Ошибка инструмента`);
        }
        if (item.kind === "reply" && item.stopReason === "end_turn") sequence.push(L`Ответ`);
        break;
      }
    }
  }
  const counts = new Map<string, FlowTransition>();
  for (let i = 0; i + 1 < sequence.length; i++) {
    const from = sequence[i];
    const to = sequence[i + 1];
    if (from === to) continue;
    const key = `${from}|${to}`;
    const t = counts.get(key);
    if (t) t.count++;
    else counts.set(key, { from, to, count: 1 });
  }
  const id = (t: FlowTransition) => `${t.from} → ${t.to}`;
  return [...counts.values()].sort((a, b) => (a.count === b.count ? (id(a) < id(b) ? -1 : 1) : b.count - a.count));
}

function buildStatus(sessionID: string, items: ActivityItem[], tools: ToolExecution[], now: number, idleAfter: number): LiveStatus | undefined {
  const relevant = items.filter((i) => i.kind !== "context" && i.kind !== "note" && i.kind !== "hook");
  const last = relevant[relevant.length - 1];
  if (!last) return undefined;
  let promptIndex = -1;
  for (let i = relevant.length - 1; i >= 0; i--) {
    if (relevant[i].kind === "prompt" && !relevant[i].isSidechain) {
      promptIndex = i;
      break;
    }
  }
  const turnItems = promptIndex >= 0 ? relevant.slice(promptIndex) : relevant;
  const turnStart = promptIndex >= 0 ? relevant[promptIndex].timestamp : undefined;
  const steps = new Set(turnItems.map((i) => i.messageID).filter(Boolean)).size;
  const toolsInTurn = turnItems.filter((i) => i.kind === "toolCall").length;
  const running = tools.filter((t) => toolIsRunning(t) && now - t.call.timestamp < RUNNING_TOOL_TIMEOUT && t.call.timestamp >= (turnStart ?? -Infinity));

  let state: LiveState;
  let since = last.timestamp;
  const latest = running.reduce<ToolExecution | undefined>((best, t) => (!best || t.call.timestamp > best.call.timestamp ? t : best), undefined);
  if (latest) {
    // Prefer the subagent call itself over the tools it runs, if one is open.
    const agent = running.find((t) => toolCat(t) === "Субагенты" && !t.call.isSidechain);
    if (agent && agent.call.id !== latest.call.id) {
      state = { type: "runningSubagent", title: `${agent.call.title} → ${latest.call.title}` };
      since = agent.call.timestamp;
    } else if (toolCat(latest) === "Субагенты") {
      state = { type: "runningSubagent", title: latest.call.title };
      since = latest.call.timestamp;
    } else {
      state = { type: "runningTool", name: toolName(latest), title: latest.call.title };
      since = latest.call.timestamp;
    }
  } else if (now - last.timestamp > idleAfter) {
    state = { type: "idle" };
  } else {
    switch (last.kind) {
      case "prompt": case "queued": case "toolResult": case "compact": case "toolCall":
        state = { type: "thinking" };
        break;
      case "thinking":
        state = { type: "writing" };
        break;
      case "reply":
        state = last.stopReason === "tool_use" || (last.stopReason === undefined && now - last.timestamp < 120_000) ? { type: "writing" } : { type: "waitingForUser" };
        break;
      case "interrupted":
        state = { type: "interrupted" };
        break;
      case "apiError":
        state = { type: "error", message: last.title };
        break;
      default:
        state = { type: "idle" };
    }
    if ((state.type === "thinking" || state.type === "writing") && now - last.timestamp > QUIET_AFTER) state = { type: "quiet" };
  }
  return { state, since, lastActivity: last.timestamp, turnStart, stepsInTurn: steps, toolsInTurn, runningTools: running.length, sessionID };
}
