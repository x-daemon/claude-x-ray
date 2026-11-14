import Foundation

/// De-duplicated, time-ordered set of usage events.
///
/// The same API response appears on several transcript lines (one per content
/// block) and, after `--resume`/`--continue`, can be copied into a new session
/// file. Events are keyed by `UsageEvent.dedupeKey`; when a key repeats, the
/// copy with the larger output count wins (a streamed response may be logged
/// before its final usage arrives).
public struct UsageStore: Sendable {
    public private(set) var events: [UsageEvent] = []
    private var indexByKey: [String: Int] = [:]

    public init() {}

    public init(events: [UsageEvent]) {
        merge(events)
    }

    public var count: Int { events.count }

    /// Merges new events. Returns how many were added or updated.
    @discardableResult
    public mutating func merge(_ newEvents: [UsageEvent]) -> Int {
        var changed = 0
        var needsSort = false

        for event in newEvents {
            let key = event.dedupeKey
            if let index = indexByKey[key] {
                if event.tokens.output > events[index].tokens.output {
                    events[index] = event
                    changed += 1
                }
                continue
            }
            if let last = events.last, event.timestamp < last.timestamp {
                needsSort = true
            }
            indexByKey[key] = events.count
            events.append(event)
            changed += 1
        }

        if needsSort {
            events.sort { lhs, rhs in
                lhs.timestamp == rhs.timestamp ? lhs.dedupeKey < rhs.dedupeKey : lhs.timestamp < rhs.timestamp
            }
            indexByKey = Dictionary(uniqueKeysWithValues: events.enumerated().map { ($1.dedupeKey, $0) })
        }
        return changed
    }

    public mutating func removeAll() {
        events.removeAll()
        indexByKey.removeAll()
    }
}
