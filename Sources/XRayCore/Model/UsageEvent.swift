import Foundation

/// A step the API ran inside one request (main answer, fallback model, server-side compaction).
public struct RequestIteration: Hashable, Sendable {
    public var type: String
    public var model: String?
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(type: String, model: String? = nil, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.type = type
        self.model = model
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// A change the API made to the request before the model saw it (e.g. a thinking block dropped).
public struct InputTransformation: Hashable, Sendable {
    public var type: String
    public var reason: String?
    public var path: String?

    public init(type: String, reason: String? = nil, path: String? = nil) {
        self.type = type
        self.reason = reason
        self.path = path
    }
}

/// Context the server cleared before the request (context editing).
public struct ContextEdit: Hashable, Sendable {
    public var type: String
    public var clearedTokens: Int?
    public var clearedToolUses: Int?

    public init(type: String, clearedTokens: Int? = nil, clearedToolUses: Int? = nil) {
        self.type = type
        self.clearedTokens = clearedTokens
        self.clearedToolUses = clearedToolUses
    }
}

/// Why the prompt cache missed, from the API's cache diagnostics.
public struct CacheMiss: Hashable, Sendable {
    public var reason: String
    /// Prompt tokens the API reports as missed, when it reports them.
    public var missedTokens: Int?

    public init(reason: String, missedTokens: Int? = nil) {
        self.reason = reason
        self.missedTokens = missedTokens
    }
}

/// API-level details of one model request, as Claude Code records them: why the response ended,
/// the cache diagnosis, what the API changed in the input, and the steps it ran.
public struct RequestDetails: Hashable, Sendable {
    /// `end_turn`, `tool_use`, `max_tokens`, `stop_sequence`, `pause_turn`, `refusal`.
    public var stopReason: String?
    /// `stop_details.category` of a refusal (cyber, bio...).
    public var stopCategory: String?
    /// Model Claude Code asked for, when the transcript has it.
    public var requestedModel: String?
    /// Advisor tool model configured for the request.
    public var advisorModel: String?
    /// Where inference ran (`usage.inference_geo`).
    public var inferenceGeo: String?
    /// Cache TTL Claude Code requested (`5m` or `1h`).
    public var cacheTTL: String?
    public var cacheMiss: CacheMiss?
    /// Changes the API made to the input, e.g. thinking blocks it dropped.
    public var transformations: [InputTransformation] = []
    /// Context the server cleared (context editing).
    public var contextEdits: [ContextEdit] = []
    /// Steps of the request when there was more than the main answer.
    public var iterations: [RequestIteration] = []

    public init() {}

    public var isEmpty: Bool {
        stopReason == nil && stopCategory == nil && requestedModel == nil && advisorModel == nil && inferenceGeo == nil
            && cacheTTL == nil && cacheMiss == nil && transformations.isEmpty && contextEdits.isEmpty && iterations.isEmpty
    }

    /// Thinking blocks the API dropped from the history before this request.
    public var droppedThinking: Int { transformations.filter { $0.type == "thinking_dropped" }.count }
}

/// One billed model request recorded by Claude Code.
public struct UsageEvent: Hashable, Sendable, Identifiable {
    /// Anthropic message id (`msg_...`).
    public let messageID: String
    /// API request id (`req_...`), when the transcript has it.
    public let requestID: String?
    public let timestamp: Date
    /// Model id as reported by the API, e.g. `claude-opus-5-5`.
    public let model: String
    public let sessionID: String
    /// Working directory of the Claude Code session.
    public let projectPath: String
    public let gitBranch: String?
    /// `true` for subagent (sidechain) requests.
    public let isSidechain: Bool
    /// Effort level Claude Code requested, e.g. `high`, `xhigh`.
    public let effort: String?
    /// `standard` or `fast`.
    public let speed: String?
    public let serviceTier: String?
    /// Claude Code version that wrote the entry.
    public let clientVersion: String?
    public let tokens: TokenCounts
    public let webSearchRequests: Int
    public let webFetchRequests: Int
    /// API-level details (stop reason, cache diagnosis...).
    public let details: RequestDetails?

    public init(
        messageID: String,
        requestID: String? = nil,
        timestamp: Date,
        model: String,
        sessionID: String,
        projectPath: String,
        gitBranch: String? = nil,
        isSidechain: Bool = false,
        effort: String? = nil,
        speed: String? = nil,
        serviceTier: String? = nil,
        clientVersion: String? = nil,
        tokens: TokenCounts,
        webSearchRequests: Int = 0,
        webFetchRequests: Int = 0,
        details: RequestDetails? = nil
    ) {
        self.messageID = messageID
        self.requestID = requestID
        self.timestamp = timestamp
        self.model = model
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.isSidechain = isSidechain
        self.effort = effort
        self.speed = speed
        self.serviceTier = serviceTier
        self.clientVersion = clientVersion
        self.tokens = tokens
        self.webSearchRequests = webSearchRequests
        self.webFetchRequests = webFetchRequests
        self.details = details
    }

    /// Claude Code writes one transcript line per content block of a response
    /// (thinking, text, tool_use...), each carrying the same `usage`.
    /// Counting every line would double or triple the bill, so events are
    /// de-duplicated on this key.
    public var dedupeKey: String {
        if let requestID, !requestID.isEmpty {
            return messageID + "|" + requestID
        }
        return messageID
    }

    public var id: String { dedupeKey }

    /// Last path component of the project directory.
    public var projectName: String {
        let trimmed = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return name.isEmpty ? projectPath : name
    }

    public var isFastMode: Bool { speed?.lowercased() == "fast" }
}
