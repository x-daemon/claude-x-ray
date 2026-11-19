import Foundation

/// How much of the claude.ai plan limits the whole account has used, as Claude Code reports it
/// to its status line (`rate_limits`). Unlike the transcripts on this Mac, it counts every
/// surface that draws on the subscription: chats, cloud sessions, Cowork and local sessions.
public struct PlanUsage: Codable, Equatable, Sendable {
    /// A rolling limit window (5 hours or 7 days).
    public struct Window: Codable, Equatable, Sendable {
        /// Share of the limit used, 0–100.
        public var usedPercentage: Double
        /// When the window resets.
        public var resetsAt: Date

        public init(usedPercentage: Double, resetsAt: Date) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }

        public func hasReset(at now: Date) -> Bool { now >= resetsAt }

        /// Used share 0...1 at `now`; zero once the window has reset.
        public func fraction(at now: Date) -> Double {
            hasReset(at: now) ? 0 : min(max(usedPercentage / 100, 0), 1)
        }
    }

    /// Spend cap set by a Claude apps gateway.
    public struct SpendLimit: Codable, Equatable, Sendable {
        public var usedPercentage: Double
        public var resetsAt: Date?
        public var usedUSD: Double?
        public var limitUSD: Double?
        public var period: String?

        public init(usedPercentage: Double, resetsAt: Date? = nil, usedUSD: Double? = nil, limitUSD: Double? = nil, period: String? = nil) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
            self.usedUSD = usedUSD
            self.limitUSD = limitUSD
            self.period = period
        }
    }

    /// When the status line received these numbers.
    public var capturedAt: Date
    public var fiveHour: Window?
    public var sevenDay: Window?
    public var spendLimit: SpendLimit?
    /// Model of the session that reported them, e.g. "Opus 5.5".
    public var model: String?
    /// Claude Code version of that session.
    public var version: String?

    public init(
        capturedAt: Date,
        fiveHour: Window? = nil,
        sevenDay: Window? = nil,
        spendLimit: SpendLimit? = nil,
        model: String? = nil,
        version: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.spendLimit = spendLimit
        self.model = model
        self.version = version
    }

    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil && spendLimit == nil }

    /// Fills the windows missing from this report with the previous report's, unless they have
    /// reset since. Claude Code may leave a window out, and drops one once it resets.
    public func merged(with previous: PlanUsage?) -> PlanUsage {
        guard let previous else { return self }
        var result = self
        if result.fiveHour == nil, let old = previous.fiveHour, !old.hasReset(at: capturedAt) {
            result.fiveHour = old
        }
        if result.sevenDay == nil, let old = previous.sevenDay, !old.hasReset(at: capturedAt) {
            result.sevenDay = old
        }
        if result.spendLimit == nil, let old = previous.spendLimit, (old.resetsAt.map { capturedAt < $0 } ?? true) {
            result.spendLimit = old
        }
        return result
    }

    // MARK: File format

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> PlanUsage? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PlanUsage.self, from: data)
    }
}

/// Reads the JSON that Claude Code passes to a status line command on stdin.
public enum StatusLineInput {
    /// Plan usage from `rate_limits`; nil when the input has none (API-key sign-in, or before the
    /// session's first response).
    public static func planUsage(from data: Data, capturedAt: Date = Date()) -> PlanUsage? {
        guard let root = object(data), let limits = root["rate_limits"] as? [String: Any] else { return nil }
        var usage = PlanUsage(capturedAt: capturedAt)
        usage.fiveHour = window(limits["five_hour"])
        usage.sevenDay = window(limits["seven_day"])
        if let spend = limits["spend_limit"] as? [String: Any], let used = number(spend["used_percentage"]) {
            usage.spendLimit = PlanUsage.SpendLimit(
                usedPercentage: used,
                resetsAt: date(spend["resets_at"]),
                usedUSD: number(spend["used_usd"]),
                limitUSD: number(spend["limit_usd"]),
                period: spend["period"] as? String
            )
        }
        usage.model = modelName(root)
        usage.version = root["version"] as? String
        return usage.isEmpty ? nil : usage
    }

    /// Status line text: `Opus 5.5 · контекст 42% · 5 ч 38% · неделя 22%`.
    public static func summaryLine(from data: Data, usage: PlanUsage?, now: Date = Date()) -> String {
        let root = object(data) ?? [:]
        var parts: [String] = []
        if let model = modelName(root) {
            parts.append(model)
        }
        if let context = root["context_window"] as? [String: Any], let used = number(context["used_percentage"]) {
            parts.append(L("контекст \(Int(used.rounded()))%"))
        }
        if let window = usage?.fiveHour, !window.hasReset(at: now) {
            parts.append(L("5 ч \(Int(window.usedPercentage.rounded()))%"))
        }
        if let window = usage?.sevenDay, !window.hasReset(at: now) {
            parts.append(L("неделя \(Int(window.usedPercentage.rounded()))%"))
        }
        return parts.isEmpty ? "S2A X-Ray" : parts.joined(separator: " · ")
    }

    // MARK: Lenient field readers

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func modelName(_ root: [String: Any]) -> String? {
        if let model = root["model"] as? [String: Any] {
            return (model["display_name"] as? String) ?? (model["id"] as? String).map(ModelCatalog.displayName(for:))
        }
        return (root["model"] as? String).map(ModelCatalog.displayName(for:))
    }

    static func window(_ raw: Any?) -> PlanUsage.Window? {
        guard let fields = raw as? [String: Any],
              let used = number(fields["used_percentage"]),
              let resets = date(fields["resets_at"]) else { return nil }
        return PlanUsage.Window(usedPercentage: used, resetsAt: resets)
    }

    static func number(_ raw: Any?) -> Double? {
        if let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.doubleValue
        }
        if let text = raw as? String {
            return Double(text)
        }
        return nil
    }

    /// Unix seconds (milliseconds when the number is that large) or an ISO 8601 string.
    static func date(_ raw: Any?) -> Date? {
        if let seconds = number(raw) {
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        if let text = raw as? String {
            return TranscriptParser.parseDate(text)
        }
        return nil
    }
}
