import Foundation

/// A Pro/Max usage window.
///
/// Subscription limits are counted in rolling 5-hour windows that start with
/// the first message. Anthropic does not publish the exact quota per window
/// and the transcripts do not carry it, so the window is reconstructed from
/// activity: it starts at the hour of the first request after the previous
/// window ended and lasts five hours. Treat it as an approximation.
public struct UsageWindow: Identifiable, Hashable, Sendable {
    public let start: Date
    public let end: Date
    public var firstActivity: Date
    public var lastActivity: Date
    public var summary: UsageSummary
    public var models: [String]

    public var id: Date { start }
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func isActive(at now: Date) -> Bool { now >= start && now < end }

    public func remaining(at now: Date) -> TimeInterval { max(0, end.timeIntervalSince(now)) }

    /// Elapsed fraction of the window, 0...1.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / duration))
    }

    /// Cost at the end of the window if spending continues at the current pace.
    public func projectedCost(at now: Date) -> Double {
        guard isActive(at: now) else { return summary.cost.total }
        let active = max(now.timeIntervalSince(firstActivity), 5 * 60)
        let rate = summary.cost.total / active
        return summary.cost.total + rate * remaining(at: now)
    }

    /// Tokens at the end of the window if usage continues at the current pace.
    public func projectedTokens(at now: Date) -> Double {
        guard isActive(at: now) else { return Double(summary.tokens.total) }
        let active = max(now.timeIntervalSince(firstActivity), 5 * 60)
        let rate = Double(summary.tokens.total) / active
        return Double(summary.tokens.total) + rate * remaining(at: now)
    }
}

public enum UsageWindows {
    public static let defaultDuration: TimeInterval = 5 * 3600

    /// Splits time-ordered events into consecutive windows.
    public static func compute(_ events: [PricedEvent], duration: TimeInterval = defaultDuration) -> [UsageWindow] {
        let sorted = events.sorted { $0.event.timestamp < $1.event.timestamp }
        var windows: [UsageWindow] = []
        var current: UsageWindow?
        var models: Set<String> = []

        func close() {
            if var window = current {
                window.models = models.sorted()
                windows.append(window)
            }
            current = nil
            models = []
        }

        for priced in sorted {
            let time = priced.event.timestamp
            if let window = current, time >= window.end {
                close()
            }
            if current == nil {
                let start = floorToHour(time)
                current = UsageWindow(
                    start: start,
                    end: start.addingTimeInterval(duration),
                    firstActivity: time,
                    lastActivity: time,
                    summary: UsageSummary(),
                    models: []
                )
            }
            current?.summary.add(priced)
            current?.lastActivity = time
            models.insert(priced.event.model)
        }
        close()
        return windows
    }

    /// Start of the UTC hour containing `date`.
    public static func floorToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    /// The window containing `now`, if one is open.
    public static func active(in windows: [UsageWindow], at now: Date) -> UsageWindow? {
        windows.last.flatMap { $0.isActive(at: now) ? $0 : nil }
    }

    /// Largest completed window by API-equivalent cost: a personal reference for "how full" a window is.
    public static func peak(in windows: [UsageWindow], excludingActiveAt now: Date) -> UsageWindow? {
        windows.filter { !$0.isActive(at: now) }.max { $0.summary.cost.total < $1.summary.cost.total }
    }
}
