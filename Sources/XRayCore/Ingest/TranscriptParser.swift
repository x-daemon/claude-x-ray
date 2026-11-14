import Foundation

/// Parses Claude Code transcript lines (`~/.claude/projects/<project>/<session>.jsonl`).
///
/// The transcript format is internal to Claude Code and not documented, so the
/// parser is deliberately lenient: every field is optional, a field with an
/// unexpected type is ignored instead of failing the whole line, and any line
/// that is not an assistant message with a `usage` object is skipped.
public enum TranscriptParser {
    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let decoder = JSONDecoder()

    /// Parses one JSONL line. Returns `nil` for lines that carry no billed usage.
    ///
    /// - Parameters:
    ///   - line: Raw bytes of one line, without the trailing newline.
    ///   - fallbackSessionID: Used when the line has no `sessionId` (normally the file name).
    ///   - fallbackProject: Used when the line has no `cwd` (normally the project folder name).
    public static func parse(
        line: Data,
        fallbackSessionID: String = "unknown",
        fallbackProject: String = "unknown"
    ) -> UsageEvent? {
        // Cheap pre-filter: most lines (user turns, tool results, attachments) never
        // carry usage, and decoding them would dominate the scan time.
        guard line.range(of: usageMarker) != nil, line.range(of: assistantMarker) != nil else {
            return nil
        }
        guard let entry = try? decoder.decode(Entry.self, from: line) else { return nil }
        guard entry.type == "assistant", let message = entry.message, let usage = message.usage else {
            return nil
        }

        let model = message.model ?? "unknown"
        // Claude Code records locally generated messages (errors, interruptions)
        // with this placeholder model; nothing was billed for them.
        if model == "<synthetic>" { return nil }

        let write5m = usage.cacheCreation?.ephemeral5m
        let write1h = usage.cacheCreation?.ephemeral1h
        let totalWrite = usage.cacheCreationInputTokens ?? 0
        let splitKnown = (write5m ?? 0) + (write1h ?? 0)
        // Older transcripts only have the total; treat it as the default 5-minute TTL.
        let cacheWrite5m = splitKnown > 0 ? (write5m ?? 0) : totalWrite
        let cacheWrite1h = splitKnown > 0 ? (write1h ?? 0) : 0

        let tokens = TokenCounts(
            input: usage.inputTokens ?? 0,
            output: usage.outputTokens ?? 0,
            cacheRead: usage.cacheReadInputTokens ?? 0,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            thinking: usage.outputTokensDetails?.thinkingTokens ?? 0
        )
        guard !tokens.isEmpty else { return nil }

        guard let timestamp = entry.timestamp.flatMap(parseDate) else { return nil }
        guard let messageID = message.id ?? entry.uuid else { return nil }

        return UsageEvent(
            messageID: messageID,
            requestID: entry.requestId,
            timestamp: timestamp,
            model: model,
            sessionID: entry.sessionId ?? fallbackSessionID,
            projectPath: entry.cwd ?? fallbackProject,
            gitBranch: entry.gitBranch.flatMap { $0.isEmpty ? nil : $0 },
            isSidechain: entry.isSidechain ?? false,
            effort: entry.effort,
            speed: usage.speed,
            serviceTier: usage.serviceTier,
            clientVersion: entry.version,
            tokens: tokens,
            webSearchRequests: usage.serverToolUse?.webSearchRequests ?? 0,
            webFetchRequests: usage.serverToolUse?.webFetchRequests ?? 0
        )
    }

    // MARK: - Dates

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }
}

// MARK: - Lenient decoding

/// Decodes a value if present and of the expected type; any mismatch yields `nil`.
private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard let value = try? decodeIfPresent(type, forKey: key) else { return nil }
        return value
    }
}

private struct Entry: Decodable {
    let type: String?
    let uuid: String?
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let gitBranch: String?
    let isSidechain: Bool?
    let effort: String?
    let version: String?
    let requestId: String?
    let message: Message?

    enum CodingKeys: String, CodingKey {
        case type, uuid, timestamp, sessionId, cwd, gitBranch, isSidechain, effort, version, requestId, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        uuid = c.lenient(String.self, .uuid)
        timestamp = c.lenient(String.self, .timestamp)
        sessionId = c.lenient(String.self, .sessionId)
        cwd = c.lenient(String.self, .cwd)
        gitBranch = c.lenient(String.self, .gitBranch)
        isSidechain = c.lenient(Bool.self, .isSidechain)
        effort = c.lenient(String.self, .effort)
        version = c.lenient(String.self, .version)
        requestId = c.lenient(String.self, .requestId)
        message = c.lenient(Message.self, .message)
    }
}

private struct Message: Decodable {
    let id: String?
    let model: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey { case id, model, usage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id)
        model = c.lenient(String.self, .model)
        usage = c.lenient(Usage.self, .usage)
    }
}

private struct Usage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheCreation: CacheCreation?
    let outputTokensDetails: OutputTokensDetails?
    let serverToolUse: ServerToolUse?
    let serviceTier: String?
    let speed: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
        case outputTokensDetails = "output_tokens_details"
        case serverToolUse = "server_tool_use"
        case serviceTier = "service_tier"
        case speed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = c.lenient(Int.self, .inputTokens)
        outputTokens = c.lenient(Int.self, .outputTokens)
        cacheReadInputTokens = c.lenient(Int.self, .cacheReadInputTokens)
        cacheCreationInputTokens = c.lenient(Int.self, .cacheCreationInputTokens)
        cacheCreation = c.lenient(CacheCreation.self, .cacheCreation)
        outputTokensDetails = c.lenient(OutputTokensDetails.self, .outputTokensDetails)
        serverToolUse = c.lenient(ServerToolUse.self, .serverToolUse)
        serviceTier = c.lenient(String.self, .serviceTier)
        speed = c.lenient(String.self, .speed)
    }
}

private struct CacheCreation: Decodable {
    let ephemeral5m: Int?
    let ephemeral1h: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral5m = "ephemeral_5m_input_tokens"
        case ephemeral1h = "ephemeral_1h_input_tokens"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ephemeral5m = c.lenient(Int.self, .ephemeral5m)
        ephemeral1h = c.lenient(Int.self, .ephemeral1h)
    }
}

private struct OutputTokensDetails: Decodable {
    let thinkingTokens: Int?

    enum CodingKeys: String, CodingKey { case thinkingTokens = "thinking_tokens" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thinkingTokens = c.lenient(Int.self, .thinkingTokens)
    }
}

private struct ServerToolUse: Decodable {
    let webSearchRequests: Int?
    let webFetchRequests: Int?

    enum CodingKeys: String, CodingKey {
        case webSearchRequests = "web_search_requests"
        case webFetchRequests = "web_fetch_requests"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        webSearchRequests = c.lenient(Int.self, .webSearchRequests)
        webFetchRequests = c.lenient(Int.self, .webFetchRequests)
    }
}
