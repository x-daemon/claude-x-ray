import XCTest
@testable import XRayCore

final class AnalyticsTests: XCTestCase {
    func testGroupsByModelSortedByCost() {
        let events = Fixture.priced([
            Fixture.assistantLine(id: "a", model: "claude-opus-5-5"),
            Fixture.assistantLine(id: "b", model: "claude-opus-5-5"),
            Fixture.assistantLine(id: "c", model: "claude-haiku-5-5"),
        ])
        let groups = Analytics.group(events) { $0.model }
        XCTAssertEqual(groups.map(\.key), ["claude-opus-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(groups.first?.requests, 2)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.cost }, UsageSummary.of(events).cost.total, accuracy: 1e-9)
    }

    func testDailyBucketsIncludeEmptyDays() {
        let events = Fixture.priced([
            Fixture.assistantLine(id: "a", timestamp: Fixture.date(2026, 11, 10, 9)),
            Fixture.assistantLine(id: "b", timestamp: Fixture.date(2026, 11, 12, 23, 59)),
        ])
        let interval = DateInterval(start: Fixture.date(2026, 11, 10, 0), end: Fixture.date(2026, 11, 13, 0))
        let buckets = Analytics.buckets(events, unit: .day, interval: interval, calendar: Fixture.utc) { $0.model }
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets.map(\.summary.requests), [1, 0, 1])
        XCTAssertEqual(buckets[2].bySeries["claude-opus-5-5"]?.requests, 1)
    }

    func testFixedBucketsForLiveChart() {
        let start = Fixture.date(2026, 11, 14, 12)
        let events = Fixture.priced([
            Fixture.assistantLine(id: "a", timestamp: start.addingTimeInterval(60)),
            Fixture.assistantLine(id: "b", timestamp: start.addingTimeInterval(4 * 60)),
            Fixture.assistantLine(id: "c", timestamp: start.addingTimeInterval(11 * 60)),
        ])
        let buckets = Analytics.fixedBuckets(events, interval: DateInterval(start: start, duration: 15 * 60), width: 5 * 60)
        XCTAssertEqual(buckets.map(\.summary.requests), [2, 0, 1])
    }

    func testHeatmapStartsOnMonday() {
        // 2026-11-16 is a Monday, 2026-11-15 a Sunday.
        let events = Fixture.priced([
            Fixture.assistantLine(id: "mon", timestamp: Fixture.date(2026, 11, 16, 9)),
            Fixture.assistantLine(id: "sun", timestamp: Fixture.date(2026, 11, 15, 22)),
        ])
        let cells = Analytics.heatmap(events, calendar: Fixture.utc)
        XCTAssertEqual(cells.count, 7 * 24)
        XCTAssertEqual(cells.first { $0.weekday == 0 && $0.hour == 9 }?.requests, 1)
        XCTAssertEqual(cells.first { $0.weekday == 6 && $0.hour == 22 }?.requests, 1)
    }

    func testBurnRateOverTrailingHour() {
        let now = Fixture.date(2026, 11, 14, 12)
        let events = Fixture.priced([
            Fixture.assistantLine(id: "old", timestamp: now.addingTimeInterval(-2 * 3600), input: 0, output: 1_000_000, cacheRead: 0, write5m: 0, write1h: 0, thinking: 0),
            Fixture.assistantLine(id: "new", timestamp: now.addingTimeInterval(-600), input: 0, output: 1_000_000, cacheRead: 0, write5m: 0, write1h: 0, thinking: 0),
        ])
        let rate = Analytics.burnRate(events, now: now, window: 3600)
        XCTAssertEqual(rate.requests, 1)
        XCTAssertEqual(rate.costPerHour, 20, accuracy: 1e-9)
    }

    func testSessionsCollectModelsSidechainsAndPeakContext() throws {
        let events = Fixture.priced([
            Fixture.assistantLine(id: "a", model: "claude-opus-5-5", cacheRead: 100_000, session: "s1"),
            Fixture.assistantLine(id: "b", model: "claude-haiku-5-5", cacheRead: 10_000, session: "s1", sidechain: true),
            Fixture.assistantLine(id: "c", session: "s2"),
        ])
        let sessions = SessionAnalytics.sessions(events)
        XCTAssertEqual(sessions.count, 2)
        let s1 = try XCTUnwrap(sessions.first { $0.id == "s1" })
        XCTAssertEqual(s1.models, ["claude-haiku-5-5", "claude-opus-5-5"])
        XCTAssertEqual(s1.requests, 2)
        XCTAssertEqual(s1.peakContextTokens, 2 + 100_000 + 20_000)
        XCTAssertGreaterThan(s1.sidechainCost, 0)
        XCTAssertEqual(s1.projectName, "app")
    }
}

final class UsageWindowsTests: XCTestCase {
    func testWindowStartsAtTheHourAndLastsFiveHours() {
        let events = Fixture.priced([
            Fixture.assistantLine(id: "a", timestamp: Fixture.date(2026, 11, 14, 10, 15)),
            Fixture.assistantLine(id: "b", timestamp: Fixture.date(2026, 11, 14, 11, 0)),
            Fixture.assistantLine(id: "c", timestamp: Fixture.date(2026, 11, 14, 14, 59)),
            Fixture.assistantLine(id: "d", timestamp: Fixture.date(2026, 11, 14, 15, 10)),
            Fixture.assistantLine(id: "e", timestamp: Fixture.date(2026, 11, 15, 9, 30)),
        ])
        let windows = UsageWindows.compute(events)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].start, Fixture.date(2026, 11, 14, 10))
        XCTAssertEqual(windows[0].end, Fixture.date(2026, 11, 14, 15))
        XCTAssertEqual(windows[0].summary.requests, 3)
        XCTAssertEqual(windows[1].start, Fixture.date(2026, 11, 14, 15))
        XCTAssertEqual(windows[2].start, Fixture.date(2026, 11, 15, 9))
    }

    func testActiveWindowProjection() throws {
        let events = Fixture.priced([
            Fixture.assistantLine(id: "a", timestamp: Fixture.date(2026, 11, 14, 10, 0), input: 0, output: 1_000_000, cacheRead: 0, write5m: 0, write1h: 0, thinking: 0),
        ])
        let windows = UsageWindows.compute(events)
        let now = Fixture.date(2026, 11, 14, 11, 0)
        let active = try XCTUnwrap(UsageWindows.active(in: windows, at: now))
        XCTAssertEqual(active.remaining(at: now), 4 * 3600, accuracy: 1e-6)
        XCTAssertEqual(active.progress(at: now), 0.2, accuracy: 1e-9)
        // $20 in the first hour -> $20/h for four more hours.
        XCTAssertEqual(active.projectedCost(at: now), 100, accuracy: 1e-6)
        XCTAssertNil(UsageWindows.active(in: windows, at: Fixture.date(2026, 11, 14, 16)))
    }

    func testPeakIgnoresTheActiveWindow() {
        let events = Fixture.priced([
            Fixture.assistantLine(id: "small", timestamp: Fixture.date(2026, 11, 13, 10), output: 100),
            Fixture.assistantLine(id: "big", timestamp: Fixture.date(2026, 11, 14, 10), output: 900_000),
        ])
        let windows = UsageWindows.compute(events)
        let peak = UsageWindows.peak(in: windows, excludingActiveAt: Fixture.date(2026, 11, 14, 11))
        XCTAssertEqual(peak?.start, Fixture.date(2026, 11, 13, 10))
    }
}
