import Foundation

/// Running totals over a set of priced events.
public struct UsageSummary: Hashable, Sendable {
    public var tokens = TokenCounts.zero
    public var cost = CostBreakdown.zero
    public var requests = 0
    public var webSearches = 0
    public var webFetches = 0
    public var estimatedRequests = 0
    public var first: Date?
    public var last: Date?

    public init() {}

    public mutating func add(_ priced: PricedEvent) {
        let event = priced.event
        tokens += event.tokens
        cost += priced.cost
        requests += 1
        webSearches += event.webSearchRequests
        webFetches += event.webFetchRequests
        if priced.isEstimated { estimatedRequests += 1 }
        if first.map({ event.timestamp < $0 }) ?? true { first = event.timestamp }
        if last.map({ event.timestamp > $0 }) ?? true { last = event.timestamp }
    }

    public static func of<S: Sequence>(_ events: S) -> UsageSummary where S.Element == PricedEvent {
        var summary = UsageSummary()
        for event in events { summary.add(event) }
        return summary
    }

    public var averageContextTokens: Double {
        requests > 0 ? Double(tokens.contextTokens) / Double(requests) : 0
    }

    public var costPerRequest: Double {
        requests > 0 ? cost.total / Double(requests) : 0
    }
}

/// A named group (model, project, branch...) with its totals.
public struct GroupSummary: Identifiable, Hashable, Sendable {
    public let key: String
    public var summary: UsageSummary
    public var id: String { key }

    public init(key: String, summary: UsageSummary) {
        self.key = key
        self.summary = summary
    }

    public var cost: Double { summary.cost.total }
    public var totalTokens: Int { summary.tokens.total }
    public var requests: Int { summary.requests }
    public var cacheHitRate: Double { summary.tokens.cacheHitRate }
}

/// Totals for one calendar bucket (a day or an hour), split by series.
public struct TimeBucket: Identifiable, Hashable, Sendable {
    public let start: Date
    public let end: Date
    public var summary: UsageSummary
    public var bySeries: [String: UsageSummary]
    public var id: Date { start }

    public init(start: Date, end: Date, summary: UsageSummary = UsageSummary(), bySeries: [String: UsageSummary] = [:]) {
        self.start = start
        self.end = end
        self.summary = summary
        self.bySeries = bySeries
    }
}

/// One cell of the weekday x hour activity grid.
public struct HeatCell: Identifiable, Hashable, Sendable {
    /// 0 = Monday ... 6 = Sunday.
    public let weekday: Int
    public let hour: Int
    public var cost: Double
    public var requests: Int
    public var id: Int { weekday * 24 + hour }
}

/// Spend velocity over a trailing window.
public struct BurnRate: Hashable, Sendable {
    public var costPerHour: Double
    public var tokensPerMinute: Double
    public var requests: Int
    public var window: TimeInterval
}

public enum Analytics {
    public static func filter(_ events: [PricedEvent], in interval: DateInterval?) -> [PricedEvent] {
        guard let interval else { return events }
        return events.filter { interval.contains($0.event.timestamp) }
    }

    /// Groups events by a key, sorted by cost (largest first).
    public static func group(_ events: [PricedEvent], by key: (UsageEvent) -> String) -> [GroupSummary] {
        var groups: [String: UsageSummary] = [:]
        for priced in events {
            groups[key(priced.event), default: UsageSummary()].add(priced)
        }
        return groups
            .map { GroupSummary(key: $0.key, summary: $0.value) }
            .sorted { $0.cost == $1.cost ? $0.key < $1.key : $0.cost > $1.cost }
    }

    /// Buckets events by calendar unit (`.day`, `.hour`, ...), every bucket between
    /// `interval.start` and `interval.end` present even when empty.
    public static func buckets(
        _ events: [PricedEvent],
        unit: Calendar.Component,
        interval: DateInterval,
        calendar: Calendar = .current,
        series: (UsageEvent) -> String
    ) -> [TimeBucket] {
        var result: [TimeBucket] = []
        var index: [Date: Int] = [:]
        guard var cursor = calendar.dateInterval(of: unit, for: interval.start)?.start else { return [] }
        var guardCount = 0
        while cursor < interval.end, guardCount < 10_000 {
            guard let bucket = calendar.dateInterval(of: unit, for: cursor) else { break }
            index[bucket.start] = result.count
            result.append(TimeBucket(start: bucket.start, end: bucket.end))
            cursor = bucket.end
            guardCount += 1
        }
        for priced in events {
            guard let start = calendar.dateInterval(of: unit, for: priced.event.timestamp)?.start,
                  let position = index[start] else { continue }
            result[position].summary.add(priced)
            result[position].bySeries[series(priced.event), default: UsageSummary()].add(priced)
        }
        return result
    }

    /// Fixed-width buckets (e.g. 5 minutes) over an interval, for live charts.
    public static func fixedBuckets(_ events: [PricedEvent], interval: DateInterval, width: TimeInterval) -> [TimeBucket] {
        guard width > 0, interval.duration > 0 else { return [] }
        let count = Int((interval.duration / width).rounded(.up))
        var result = (0..<count).map { i in
            TimeBucket(
                start: interval.start.addingTimeInterval(Double(i) * width),
                end: interval.start.addingTimeInterval(Double(i + 1) * width)
            )
        }
        for priced in events {
            let offset = priced.event.timestamp.timeIntervalSince(interval.start)
            guard offset >= 0 else { continue }
            let i = Int(offset / width)
            guard i < count else { continue }
            result[i].summary.add(priced)
        }
        return result
    }

    /// Weekday x hour grid (Monday first), all 168 cells present.
    public static func heatmap(_ events: [PricedEvent], calendar: Calendar = .current) -> [HeatCell] {
        var cells = (0..<7).flatMap { day in (0..<24).map { HeatCell(weekday: day, hour: $0, cost: 0, requests: 0) } }
        for priced in events {
            let parts = calendar.dateComponents([.weekday, .hour], from: priced.event.timestamp)
            guard let weekday = parts.weekday, let hour = parts.hour else { continue }
            // Calendar.weekday: 1 = Sunday ... 7 = Saturday -> 0 = Monday ... 6 = Sunday.
            let mondayFirst = (weekday + 5) % 7
            let i = mondayFirst * 24 + hour
            cells[i].cost += priced.cost.total
            cells[i].requests += 1
        }
        return cells
    }

    public static func burnRate(_ events: [PricedEvent], now: Date, window: TimeInterval = 3600) -> BurnRate {
        let from = now.addingTimeInterval(-window)
        let recent = events.filter { $0.event.timestamp > from && $0.event.timestamp <= now }
        let summary = UsageSummary.of(recent)
        return BurnRate(
            costPerHour: summary.cost.total / (window / 3600),
            tokensPerMinute: Double(summary.tokens.total) / (window / 60),
            requests: summary.requests,
            window: window
        )
    }

    /// Share of requests per effort level (`nil` effort counted as "default").
    public static func effortDistribution(_ events: [PricedEvent]) -> [GroupSummary] {
        group(events) { $0.effort ?? "default" }
    }
}
