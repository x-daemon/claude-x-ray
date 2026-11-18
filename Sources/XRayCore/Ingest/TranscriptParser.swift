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
            // The effort of this turn; `effort` alone is the session default.
            effort: entry.perTurnEffort ?? entry.effort,
            speed: usage.speed,
            serviceTier: usage.serviceTier,
            clientVersion: entry.version,
            tokens: tokens,
            webSearchRequests: usage.serverToolUse?.webSearchRequests ?? 0,
            webFetchRequests: usage.serverToolUse?.webFetchRequests ?? 0,
            details: details(entry: entry, message: message, usage: usage)
        )
    }

    /// Stop reason, cache diagnosis, input transformations, context edits and iterations of a request.
    private static func details(entry: Entry, message: Message, usage: Usage) -> RequestDetails? {
        var details = RequestDetails()
        details.stopReason = message.stopReason.flatMap { $0.isEmpty ? nil : $0 }
        details.stopCategory = message.stopDetails?.category
        details.requestedModel = entry.requestedModel
        details.advisorModel = entry.advisorModel
        details.inferenceGeo = usage.inferenceGeo.flatMap { $0.isEmpty ? nil : $0 }
        details.cacheTTL = entry.promptCacheRequested
        if let miss = message.diagnostics?.cacheMissReason, let reason = miss.type {
            details.cacheMiss = CacheMiss(reason: reason, missedTokens: miss.missedTokens)
        }
        details.transformations = (message.inputTransformations ?? []).map {
            InputTransformation(type: $0.type ?? "unknown", reason: $0.reason, path: $0.path)
        }
        details.contextEdits = (message.contextManagement?.appliedEdits ?? []).map {
            ContextEdit(type: $0.type ?? "unknown", clearedTokens: $0.clearedInputTokens, clearedToolUses: $0.clearedToolUses)
        }
        let iterations = (usage.iterations ?? []).map { item in
            RequestIteration(
                type: item.type ?? "message",
                model: item.model,
                input: item.inputTokens ?? 0,
                output: item.outputTokens ?? 0,
                cacheRead: item.cacheReadInputTokens ?? 0,
                cacheWrite: item.cacheCreationInputTokens ?? ((item.cacheCreation?.ephemeral5m ?? 0) + (item.cacheCreation?.ephemeral1h ?? 0))
            )
        }
        // A single plain "message" step is the request itself; keep only what adds information.
        if iterations.count > 1 || iterations.contains(where: { $0.type != "message" }) {
            details.iterations = iterations
        }
        return details.isEmpty ? nil : details
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
    let perTurnEffort: String?
    let requestedModel: String?
    let advisorModel: String?
    let promptCacheRequested: String?
    let version: String?
    let requestId: String?
    let message: Message?

    enum CodingKeys: String, CodingKey {
        case type, uuid, timestamp, sessionId, cwd, gitBranch, isSidechain, effort, perTurnEffort, requestedModel, advisorModel
        case promptCacheRequested, version, requestId, message
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
        perTurnEffort = c.lenient(String.self, .perTurnEffort)
        requestedModel = c.lenient(String.self, .requestedModel)
        advisorModel = c.lenient(String.self, .advisorModel)
        promptCacheRequested = c.lenient(String.self, .promptCacheRequested)
        version = c.lenient(String.self, .version)
        requestId = c.lenient(String.self, .requestId)
        message = c.lenient(Message.self, .message)
    }
}

private struct Message: Decodable {
    let id: String?
    let model: String?
    let usage: Usage?
    let stopReason: String?
    let stopDetails: StopDetails?
    let diagnostics: Diagnostics?
    let inputTransformations: [Transformation]?
    let contextManagement: ContextManagement?

    enum CodingKeys: String, CodingKey {
        case id, model, usage, diagnostics
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
        case inputTransformations = "input_transformations"
        case contextManagement = "context_management"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id)
        model = c.lenient(String.self, .model)
        usage = c.lenient(Usage.self, .usage)
        stopReason = c.lenient(String.self, .stopReason)
        stopDetails = c.lenient(StopDetails.self, .stopDetails)
        diagnostics = c.lenient(Diagnostics.self, .diagnostics)
        inputTransformations = c.lenient([Transformation].self, .inputTransformations)
        contextManagement = c.lenient(ContextManagement.self, .contextManagement)
    }
}

private struct StopDetails: Decodable {
    let category: String?

    enum CodingKeys: String, CodingKey { case category }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = c.lenient(String.self, .category)
    }
}

private struct Diagnostics: Decodable {
    let cacheMissReason: MissReason?

    enum CodingKeys: String, CodingKey { case cacheMissReason = "cache_miss_reason" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cacheMissReason = c.lenient(MissReason.self, .cacheMissReason)
    }
}

private struct MissReason: Decodable {
    let type: String?
    let missedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case missedTokens = "cache_missed_input_tokens"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        missedTokens = c.lenient(Int.self, .missedTokens)
    }
}

private struct Transformation: Decodable {
    let type: String?
    let reason: String?
    let path: String?

    enum CodingKeys: String, CodingKey { case type, reason, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        reason = c.lenient(String.self, .reason)
        path = c.lenient(String.self, .path)
    }
}

private struct ContextManagement: Decodable {
    let appliedEdits: [AppliedEdit]?

    enum CodingKeys: String, CodingKey { case appliedEdits = "applied_edits" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appliedEdits = c.lenient([AppliedEdit].self, .appliedEdits)
    }
}

private struct AppliedEdit: Decodable {
    let type: String?
    let clearedInputTokens: Int?
    let clearedToolUses: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case clearedInputTokens = "cleared_input_tokens"
        case clearedToolUses = "cleared_tool_uses"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        clearedInputTokens = c.lenient(Int.self, .clearedInputTokens)
        clearedToolUses = c.lenient(Int.self, .clearedToolUses)
    }
}

private struct Iteration: Decodable {
    let type: String?
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheCreation: CacheCreation?

    enum CodingKeys: String, CodingKey {
        case type, model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        model = c.lenient(String.self, .model)
        inputTokens = c.lenient(Int.self, .inputTokens)
        outputTokens = c.lenient(Int.self, .outputTokens)
        cacheReadInputTokens = c.lenient(Int.self, .cacheReadInputTokens)
        cacheCreationInputTokens = c.lenient(Int.self, .cacheCreationInputTokens)
        cacheCreation = c.lenient(CacheCreation.self, .cacheCreation)
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
    let inferenceGeo: String?
    let iterations: [Iteration]?

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
        case inferenceGeo = "inference_geo"
        case iterations
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
        inferenceGeo = c.lenient(String.self, .inferenceGeo)
        iterations = c.lenient([Iteration].self, .iterations)
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
