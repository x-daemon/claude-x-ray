import Foundation

/// One Claude Code session (one transcript), with its totals.
public struct SessionSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public var projectPath: String
    public var gitBranch: String?
    public var start: Date
    public var end: Date
    public var models: [String]
    public var summary: UsageSummary
    /// API-equivalent cost of subagent (sidechain) requests.
    public var sidechainCost: Double
    /// Largest prompt (fresh input + cache) seen in the session.
    public var peakContextTokens: Int

    public var projectName: String {
        let name = projectPath.split(separator: "/").last.map(String.init) ?? projectPath
        return name.isEmpty ? projectPath : name
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var cost: Double { summary.cost.total }
    public var totalTokens: Int { summary.tokens.total }
    public var requests: Int { summary.requests }
    public var cacheHitRate: Double { summary.tokens.cacheHitRate }
    public var modelsLabel: String { models.map(ModelCatalog.displayName(for:)).joined(separator: ", ") }
}

public enum SessionAnalytics {
    /// Builds one summary per session, most expensive first.
    public static func sessions(_ events: [PricedEvent]) -> [SessionSummary] {
        var byID: [String: SessionSummary] = [:]
        var modelSets: [String: Set<String>] = [:]

        for priced in events {
            let event = priced.event
            let id = event.sessionID
            modelSets[id, default: []].insert(event.model)
            if var session = byID[id] {
                session.summary.add(priced)
                session.start = min(session.start, event.timestamp)
                session.end = max(session.end, event.timestamp)
                if event.isSidechain { session.sidechainCost += priced.cost.total }
                session.peakContextTokens = max(session.peakContextTokens, event.tokens.contextTokens)
                if session.gitBranch == nil { session.gitBranch = event.gitBranch }
                byID[id] = session
            } else {
                var summary = UsageSummary()
                summary.add(priced)
                byID[id] = SessionSummary(
                    id: id,
                    projectPath: event.projectPath,
                    gitBranch: event.gitBranch,
                    start: event.timestamp,
                    end: event.timestamp,
                    models: [],
                    summary: summary,
                    sidechainCost: event.isSidechain ? priced.cost.total : 0,
                    peakContextTokens: event.tokens.contextTokens
                )
            }
        }

        return byID.values
            .map { session in
                var session = session
                session.models = (modelSets[session.id] ?? []).sorted()
                return session
            }
            .sorted { $0.cost == $1.cost ? $0.start > $1.start : $0.cost > $1.cost }
    }
}
