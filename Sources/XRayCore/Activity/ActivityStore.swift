import Foundation

/// A session seen in the activity trace, for the session picker.
public struct SessionActivity: Identifiable, Hashable, Sendable {
    public let id: String
    public var projectPath: String
    public var gitBranch: String?
    public var firstActivity: Date
    public var lastActivity: Date
    public var items: Int
    public var toolCalls: Int
    public var errors: Int
    public var lastTitle: String

    public var projectName: String {
        let name = projectPath.split(separator: "/").last.map(String.init) ?? projectPath
        return name.isEmpty ? projectPath : name
    }
}

/// Recent activity items, de-duplicated and time-ordered, with bounded retention.
public struct ActivityStore: Sendable {
    public private(set) var items: [ActivityItem] = []
    private var ids: Set<String> = []
    /// Items older than this are dropped on `prune`.
    public var retention: TimeInterval
    /// Hard cap on stored items; the oldest are dropped first.
    public var capacity: Int

    public init(retention: TimeInterval = 3 * 86_400, capacity: Int = 40_000) {
        self.retention = retention
        self.capacity = capacity
    }

    public var count: Int { items.count }

    /// Adds new items. Returns how many were new.
    @discardableResult
    public mutating func merge(_ newItems: [ActivityItem], now: Date = Date()) -> Int {
        var added = 0
        var needsSort = false
        let cutoff = now.addingTimeInterval(-retention)
        for item in newItems where item.timestamp >= cutoff {
            guard ids.insert(item.id).inserted else { continue }
            if let last = items.last, item.timestamp < last.timestamp { needsSort = true }
            items.append(item)
            added += 1
        }
        if needsSort {
            // Stable for equal timestamps: blocks of one response keep their order.
            items = items.enumerated()
                .sorted { $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp }
                .map(\.element)
        }
        if items.count > capacity {
            drop(items.count - capacity)
        }
        return added
    }

    /// Drops items older than the retention period.
    public mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-retention)
        let stale = items.prefix { $0.timestamp < cutoff }.count
        if stale > 0 { drop(stale) }
    }

    public mutating func removeAll() {
        items.removeAll()
        ids.removeAll()
    }

    private mutating func drop(_ count: Int) {
        for item in items.prefix(count) { ids.remove(item.id) }
        items.removeFirst(count)
    }

    public func items(forSession id: String) -> [ActivityItem] {
        items.filter { $0.sessionID == id }
    }

    /// Sessions with activity, most recently active first.
    public func sessions() -> [SessionActivity] {
        var byID: [String: SessionActivity] = [:]
        for item in items {
            if var session = byID[item.sessionID] {
                session.lastActivity = max(session.lastActivity, item.timestamp)
                session.firstActivity = min(session.firstActivity, item.timestamp)
                session.items += 1
                if item.kind == .toolCall { session.toolCalls += 1 }
                if item.isError { session.errors += 1 }
                if item.kind != .context { session.lastTitle = item.title }
                if session.gitBranch == nil { session.gitBranch = item.gitBranch }
                if session.projectPath == "unknown" { session.projectPath = item.projectPath }
                byID[item.sessionID] = session
            } else {
                byID[item.sessionID] = SessionActivity(
                    id: item.sessionID,
                    projectPath: item.projectPath,
                    gitBranch: item.gitBranch,
                    firstActivity: item.timestamp,
                    lastActivity: item.timestamp,
                    items: 1,
                    toolCalls: item.kind == .toolCall ? 1 : 0,
                    errors: item.isError ? 1 : 0,
                    lastTitle: item.title
                )
            }
        }
        return byID.values.sorted { $0.lastActivity > $1.lastActivity }
    }
}
