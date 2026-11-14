import Foundation

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
        webFetchRequests: Int = 0
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
