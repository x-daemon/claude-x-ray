import Foundation

/// What a transcript entry represents in the activity trace.
public enum ActivityKind: String, Sendable, Hashable, CaseIterable {
    /// A message typed by the user (or a slash command).
    case prompt
    /// A message the user typed while Claude was busy (queued / delivered mid-turn).
    case queued
    /// The user interrupted the turn.
    case interrupted
    /// A thinking block (often empty text; duration is known).
    case thinking
    /// Visible assistant text.
    case reply
    /// Claude called a tool (built-in, MCP, skill, subagent, server tool).
    case toolCall
    /// The result of a tool call.
    case toolResult
    /// Hooks that ran (e.g. Stop hooks).
    case hook
    /// Context compaction boundary or summary.
    case compact
    /// Context/environment update: tool and skill listings, MCP servers, model, permissions...
    case context
    /// Locally generated error message (API errors, overload, prompt too long...).
    case apiError
    /// Any other system note.
    case note
}

/// Kind of file operation a tool call performs.
public enum FileAction: String, Sendable, Hashable, CaseIterable {
    case read, write, edit
}

/// Structured data carried by context/environment updates.
public enum ContextPayload: Hashable, Sendable {
    /// Deferred tool listing changed. MCP server status lists come with it.
    case tools(added: [String], removed: [String], pendingMCP: [String], failedMCP: [String], needsAuthMCP: [String], listingChars: Int)
    case skills(names: [String], count: Int, listingChars: Int)
    case mcpInstructions(added: [String], removed: [String], chars: Int)
    case agents(added: [String], removed: [String], chars: Int)
    case systemPrompt(chars: Int, parts: Int)
    case environment([String: String])
    case model(id: String, name: String?, knowledgeCutoff: String?)
    case autoMode([String: String])
    case permissions(allowed: [String])
    case editedFile(path: String)
    case tasks(count: Int)
    case remoteChange(commit: String?, pullRequest: String?, url: String?)
}

/// One step of what Claude Code did, reconstructed from a transcript line.
public struct ActivityItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: ActivityKind
    public let timestamp: Date
    public let sessionID: String
    public let projectPath: String
    public let gitBranch: String?
    public let isSidechain: Bool

    /// One-line summary.
    public var title: String
    /// Longer text (truncated): prompt text, command, output preview...
    public var detail: String?
    public var isError: Bool

    // Assistant side
    /// API message id; joins the item with its usage and cost.
    public var messageID: String?
    public var model: String?
    public var requestedModel: String?
    public var stopReason: String?
    public var effort: String?
    /// How long the thinking block took.
    public var thinkingMs: Int?
    /// How long the model took to stream the tool input (large Write/Edit inputs take seconds).
    public var inputStreamMs: Int?
    /// Skill the response is attributed to.
    public var attributionSkill: String?

    // Tools
    /// For calls: the tool_use id. For results: the call they answer.
    public var toolUseID: String?
    public var toolName: String?
    /// File path, URL, skill name, MCP server... whatever the call is about.
    public var target: String?
    public var fileAction: FileAction?
    /// How the call was permitted, e.g. "accept · правило (cliArg)".
    public var permission: String?
    /// Size of the tool output / content in bytes.
    public var outputBytes: Int?
    /// Lines added / removed by an edit (from the structured patch).
    public var linesAdded: Int?
    public var linesRemoved: Int?
    /// Thinking: how the API returned the text (`omitted`, `summarized`, `updates`).
    public var thinkingDisplay: String?
    /// Tool call: the arguments as the model generated them (compact JSON, truncated).
    public var rawInput: String?
    /// Tool call: the arguments Claude Code ran, when it changed the model's arguments.
    public var execInput: String?
    /// Tool result: accept or reject.
    public var decision: String?
    /// Tool result: who decided (classifier, rule, user, hook...).
    public var decidedBy: String?
    /// Tool result: where the deciding rule came from (cliArg, localSettings...).
    public var ruleSource: String?
    /// Tool result: the command ran in the sandbox.
    public var sandboxed: Bool?

    // Context
    public var context: ContextPayload?

    public init(
        id: String,
        kind: ActivityKind,
        timestamp: Date,
        sessionID: String,
        projectPath: String,
        gitBranch: String? = nil,
        isSidechain: Bool = false,
        title: String,
        detail: String? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.isSidechain = isSidechain
        self.title = title
        self.detail = detail
        self.isError = isError
    }

    /// `server` for `mcp__server__tool` tool names.
    public var mcpServer: String? { toolName.flatMap(ToolDescriber.mcpServer(of:)) }

    public var projectName: String {
        let name = projectPath.split(separator: "/").last.map(String.init) ?? projectPath
        return name.isEmpty ? projectPath : name
    }
}
