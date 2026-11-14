import Foundation

/// Token counters for one request (or a sum of requests).
///
/// Mirrors the `usage` object Claude Code writes into its transcripts:
/// `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
/// `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`
/// and `output_tokens_details.thinking_tokens`.
public struct TokenCounts: Codable, Hashable, Sendable {
    /// Fresh (uncached) input tokens.
    public var input: Int
    /// Output tokens, thinking included.
    public var output: Int
    /// Input tokens served from the prompt cache.
    public var cacheRead: Int
    /// Input tokens written to the cache with the 5-minute TTL.
    public var cacheWrite5m: Int
    /// Input tokens written to the cache with the 1-hour TTL.
    public var cacheWrite1h: Int
    /// Thinking tokens (a subset of `output`).
    public var thinking: Int

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        thinking: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.thinking = thinking
    }

    public static let zero = TokenCounts()

    /// All cache writes, both TTLs.
    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    /// Everything the model read for the request: fresh input + cache reads + cache writes.
    public var contextTokens: Int { input + cacheRead + cacheWrite }

    /// Every token billed for the request.
    public var total: Int { contextTokens + output }

    /// Share of the prompt that was served from the cache, 0...1.
    public var cacheHitRate: Double {
        contextTokens > 0 ? Double(cacheRead) / Double(contextTokens) : 0
    }

    public var isEmpty: Bool { total == 0 }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            thinking: lhs.thinking + rhs.thinking
        )
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}
