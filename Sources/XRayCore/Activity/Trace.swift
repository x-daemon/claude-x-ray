import Foundation

/// A tool call joined with its result.
public struct ToolExecution: Identifiable, Hashable, Sendable {
    public let call: ActivityItem
    public var result: ActivityItem?

    public var id: String { call.id }
    public var name: String { call.toolName ?? "tool" }
    public var category: ToolDescriber.Category { ToolDescriber.category(of: name) }
    public var start: Date { call.timestamp }
    public var end: Date? { result?.timestamp }
    public var isRunning: Bool { result == nil }
    public var isError: Bool { result?.isError ?? false }
    public var mcpServer: String? { ToolDescriber.mcpServer(of: name) }

    public func duration(now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }
}

/// One model response (all blocks sharing an API message id).
public struct ModelStep: Identifiable, Hashable, Sendable {
    public let messageID: String
    public var model: String?
    public var requestedModel: String?
    public var effort: String?
    /// When the model started working: the prompt or tool result it answers.
    public var start: Date
    /// When its last block was written.
    public var end: Date
    public var thinkingMs: Int
    public var inputStreamMs: Int
    public var toolCallIDs: [String]
    public var replyText: String?
    public var stopReason: String?
    public var isSidechain: Bool
    public var attributionSkill: String?

    public var id: String { messageID }
    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// Element of a turn's flow tree.
public enum FlowNode: Identifiable, Hashable, Sendable {
    case step(ModelStep, children: [FlowNode])
    case tool(ToolExecution)
    case item(ActivityItem)

    public var id: String {
        switch self {
        // A response interleaved with subagent blocks can appear twice in a turn.
        case .step(let step, let children): return "step|" + step.messageID + "|" + (children.first?.id ?? "")
        case .tool(let tool): return "tool|" + tool.id
        case .item(let item): return "item|" + item.id
        }
    }
}

public enum TurnOutcome: String, Sendable {
    case inProgress, completed, interrupted, failed
}

/// Everything between two user prompts.
public struct TraceTurn: Identifiable, Hashable, Sendable {
    public let id: String
    public let index: Int
    public var prompt: ActivityItem?
    public var start: Date
    public var end: Date
    public var nodes: [FlowNode]
    public var stepIDs: [String]
    public var toolCalls: Int
    public var errors: Int
    public var outcome: TurnOutcome

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

public struct FileTouch: Identifiable, Hashable, Sendable {
    public let path: String
    public var reads = 0
    public var writes = 0
    public var edits = 0
    public var errors = 0
    public var linesAdded = 0
    public var linesRemoved = 0
    public var last: Date

    public var id: String { path }
    public var total: Int { reads + writes + edits }
}

public struct ToolStat: Identifiable, Hashable, Sendable {
    public let name: String
    public var category: ToolDescriber.Category
    public var calls = 0
    public var errors = 0
    public var running = 0
    public var totalDuration: TimeInterval = 0
    public var maxDuration: TimeInterval = 0
    public var inputStreamMs = 0
    public var outputBytes = 0

    public var id: String { name }
    public var completed: Int { calls - running }
    public var averageDuration: TimeInterval { completed > 0 ? totalDuration / Double(completed) : 0 }
}

public enum MCPStatus: String, Sendable, CaseIterable {
    case connected, pending, failed, needsAuth, usedOnly

    public var title: String {
        switch self {
        case .connected: return L("Подключён")
        case .pending: return L("Подключается")
        case .failed: return L("Ошибка подключения")
        case .needsAuth: return L("Нужна авторизация")
        case .usedOnly: return L("Вызывался")
        }
    }
}

public struct MCPServerUsage: Identifiable, Hashable, Sendable {
    public let name: String
    public var status: MCPStatus
    public var toolsAvailable = 0
    public var hasInstructions = false
    public var calls = 0
    public var errors = 0
    public var totalDuration: TimeInterval = 0
    public var tools: [String: Int] = [:]

    public var id: String { name }
}

public struct SkillUsage: Identifiable, Hashable, Sendable {
    public let name: String
    public var available = false
    public var invocations = 0
    public var attributedSteps = 0
    public var lastUsed: Date?

    public var id: String { name }
}

public struct SubagentUsage: Identifiable, Hashable, Sendable {
    public let type: String
    public var available = false
    public var calls = 0
    public var running = 0
    public var errors = 0
    public var totalDuration: TimeInterval = 0

    public var id: String { type }
}

/// What the session's context is made of, as far as the transcript reveals.
public struct ContextSnapshot: Hashable, Sendable {
    public var modelID: String?
    public var modelName: String?
    public var knowledgeCutoff: String?
    public var systemPromptChars: Int?
    public var skillListingChars = 0
    public var mcpInstructionChars = 0
    public var agentListingChars = 0
    public var toolListingChars = 0
    public var deferredTools: [String] = []
    public var skills: [String] = []
    public var subagentTypes: [String] = []
    public var mcpWithInstructions: [String] = []
    public var pendingMCP: [String] = []
    public var failedMCP: [String] = []
    public var needsAuthMCP: [String] = []
    public var environment: [String: String] = [:]
    public var autoMode: [String: String]?
    public var allowedRules: [String] = []
    public var editedFiles: [String] = []
    public var taskCount: Int?
    public var compactions = 0
    public var lastRemoteChange: String?

    public init() {}

    /// Rough token estimate for text (≈ 4 characters per token).
    public static func estimatedTokens(chars: Int) -> Int { chars / 4 }

    /// Known parts of the context with estimated token counts.
    public var knownComponents: [(name: String, tokens: Int)] {
        let all: [(name: String, tokens: Int)] = [
            (name: L("Системный промпт"), tokens: Self.estimatedTokens(chars: systemPromptChars ?? 0)),
            (name: L("Список скиллов"), tokens: Self.estimatedTokens(chars: skillListingChars)),
            (name: L("Инструкции MCP"), tokens: Self.estimatedTokens(chars: mcpInstructionChars)),
            (name: L("Типы субагентов"), tokens: Self.estimatedTokens(chars: agentListingChars)),
            (name: L("Список отложенных инструментов"), tokens: Self.estimatedTokens(chars: toolListingChars)),
        ]
        return all.filter { $0.tokens > 0 }
    }
}

public struct PermissionStat: Identifiable, Hashable, Sendable {
    public let label: String
    public var count: Int
    public var id: String { label }
}

/// How often one kind of step follows another.
public struct FlowTransition: Identifiable, Hashable, Sendable {
    public let from: String
    public let to: String
    public var count: Int
    public var id: String { from + " → " + to }
}

/// What Claude Code is doing right now in a session.
public enum LiveState: Hashable, Sendable {
    case runningTool(name: String, title: String)
    case runningSubagent(title: String)
    /// The model is working on a prompt or tool result (thinking or preparing a response).
    case thinking
    /// The model is streaming a response after a thinking block.
    case writing
    case waitingForUser
    case interrupted
    case error(String)
    case idle

    public var isActive: Bool {
        switch self {
        case .runningTool, .runningSubagent, .thinking, .writing: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .runningTool(let name, _): return L("Выполняет \(name)")
        case .runningSubagent: return L("Работает субагент")
        case .thinking: return L("Думает")
        case .writing: return L("Пишет ответ")
        case .waitingForUser: return L("Ждёт вас")
        case .interrupted: return L("Прервано")
        case .error: return L("Ошибка")
        case .idle: return L("Нет активности")
        }
    }

    public var detail: String? {
        switch self {
        case .runningTool(_, let title): return title
        case .runningSubagent(let title): return title
        case .error(let message): return message
        default: return nil
        }
    }
}

public struct LiveStatus: Hashable, Sendable {
    public var state: LiveState
    /// When the current state began.
    public var since: Date
    public var lastActivity: Date
    public var turnStart: Date?
    public var stepsInTurn: Int
    public var toolsInTurn: Int
    public var runningTools: Int
    public var sessionID: String

    public func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(since)) }
}

/// The reconstructed activity of one session.
public struct SessionTrace: Sendable {
    public let sessionID: String
    public var items: [ActivityItem] = []
    public var steps: [ModelStep] = []
    public var tools: [ToolExecution] = []
    public var turns: [TraceTurn] = []
    public var files: [FileTouch] = []
    public var toolStats: [ToolStat] = []
    public var mcpServers: [MCPServerUsage] = []
    public var skills: [SkillUsage] = []
    public var subagents: [SubagentUsage] = []
    public var context = ContextSnapshot()
    public var permissions: [PermissionStat] = []
    public var transitions: [FlowTransition] = []
    public var status: LiveStatus?
    public var errors = 0
    public var prompts = 0

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    public var projectPath: String? { items.first { $0.projectPath != "unknown" }?.projectPath }
    public var gitBranch: String? { items.last { $0.gitBranch != nil }?.gitBranch }
    public var start: Date? { items.first?.timestamp }
    public var end: Date? { items.last?.timestamp }

    public func step(_ messageID: String) -> ModelStep? { steps.first { $0.messageID == messageID } }
}
