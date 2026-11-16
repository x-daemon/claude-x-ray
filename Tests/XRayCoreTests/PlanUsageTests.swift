import XCTest
@testable import XRayCore

final class PlanUsageTests: XCTestCase {
    /// The example from the Claude Code status line documentation, inside a fuller input.
    private let documented = """
    {
      "session_id": "abc123",
      "model": {"id": "claude-opus-5-5", "display_name": "Opus 5.5"},
      "version": "2.1.325",
      "context_window": {"used_percentage": 41.6},
      "rate_limits": {
        "five_hour": {"used_percentage": 23.5, "resets_at": 1738425600},
        "seven_day": {"used_percentage": 41.2, "resets_at": 1738857600},
        "spend_limit": {"used_percentage": 62.8, "resets_at": 1740787200, "used_usd": 314.12, "limit_usd": 500, "period": "monthly"}
      }
    }
    """

    func testReadsRateLimitsFromStatusLineInput() throws {
        let captured = Date(timeIntervalSince1970: 1_738_420_000)
        let usage = try XCTUnwrap(StatusLineInput.planUsage(from: Data(documented.utf8), capturedAt: captured))
        XCTAssertEqual(usage.capturedAt, captured)
        XCTAssertEqual(usage.fiveHour, PlanUsage.Window(usedPercentage: 23.5, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)))
        XCTAssertEqual(usage.sevenDay?.usedPercentage, 41.2)
        XCTAssertEqual(usage.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_738_857_600))
        XCTAssertEqual(usage.spendLimit?.usedUSD, 314.12)
        XCTAssertEqual(usage.spendLimit?.limitUSD, 500)
        XCTAssertEqual(usage.spendLimit?.period, "monthly")
        XCTAssertEqual(usage.model, "Opus 5.5")
        XCTAssertEqual(usage.version, "2.1.325")
    }

    func testNoRateLimitsMeansNoUsage() {
        XCTAssertNil(StatusLineInput.planUsage(from: Data(#"{"model": {"id": "claude-sonnet-5-5"}}"#.utf8)))
        XCTAssertNil(StatusLineInput.planUsage(from: Data(#"{"rate_limits": {}}"#.utf8)))
        XCTAssertNil(StatusLineInput.planUsage(from: Data("not json".utf8)))
    }

    func testAcceptsStringsMillisecondsAndISODates() throws {
        let json = #"{"model": "claude-sonnet-5-5", "rate_limits": {"five_hour": {"used_percentage": "7", "resets_at": 1738425600000}, "seven_day": {"used_percentage": 12, "resets_at": "2025-02-06T16:00:00Z"}}}"#
        let usage = try XCTUnwrap(StatusLineInput.planUsage(from: Data(json.utf8)))
        XCTAssertEqual(usage.fiveHour?.usedPercentage, 7)
        XCTAssertEqual(usage.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_738_425_600))
        XCTAssertEqual(usage.sevenDay?.resetsAt, Fixture.date(2025, 2, 6, 16))
        XCTAssertEqual(usage.model, "Sonnet 5.5")
    }

    func testWindowFractionDropsToZeroAfterReset() {
        let resets = Date(timeIntervalSince1970: 1_000_000)
        let window = PlanUsage.Window(usedPercentage: 87, resetsAt: resets)
        XCTAssertEqual(window.fraction(at: resets.addingTimeInterval(-1)), 0.87, accuracy: 1e-9)
        XCTAssertEqual(window.fraction(at: resets), 0)
        XCTAssertEqual(PlanUsage.Window(usedPercentage: 140, resetsAt: resets).fraction(at: .distantPast), 1)
    }

    func testMergeKeepsWindowsUntilTheyReset() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let previous = PlanUsage(
            capturedAt: t0,
            fiveHour: .init(usedPercentage: 30, resetsAt: t0.addingTimeInterval(600)),
            sevenDay: .init(usedPercentage: 10, resetsAt: t0.addingTimeInterval(86_400))
        )
        // Ten minutes later only the weekly window is reported: the 5-hour one has reset.
        let later = PlanUsage(capturedAt: t0.addingTimeInterval(601), sevenDay: .init(usedPercentage: 11, resetsAt: t0.addingTimeInterval(86_400)))
        let merged = later.merged(with: previous)
        XCTAssertNil(merged.fiveHour)
        XCTAssertEqual(merged.sevenDay?.usedPercentage, 11)

        // A report with only the 5-hour window keeps the weekly one that has not reset.
        let soon = PlanUsage(capturedAt: t0.addingTimeInterval(60), fiveHour: .init(usedPercentage: 31, resetsAt: t0.addingTimeInterval(600)))
        XCTAssertEqual(soon.merged(with: previous).sevenDay?.usedPercentage, 10)
        XCTAssertEqual(soon.merged(with: nil), soon)
    }

    func testFileRoundTrip() throws {
        let usage = try XCTUnwrap(StatusLineInput.planUsage(from: Data(documented.utf8), capturedAt: Date(timeIntervalSince1970: 1_738_420_000)))
        XCTAssertEqual(PlanUsage.decode(try usage.encoded()), usage)
        XCTAssertNil(PlanUsage.decode(Data("{}".utf8)))
    }

    func testSummaryLine() throws {
        let data = Data(documented.utf8)
        let now = Date(timeIntervalSince1970: 1_738_420_000)
        let usage = StatusLineInput.planUsage(from: data, capturedAt: now)
        XCTAssertEqual(StatusLineInput.summaryLine(from: data, usage: usage, now: now), "Opus 5.5 · контекст 42% · 5 ч 24% · неделя 41%")
        // After the 5-hour window resets it is left out.
        let later = Date(timeIntervalSince1970: 1_738_425_601)
        XCTAssertEqual(StatusLineInput.summaryLine(from: data, usage: usage, now: later), "Opus 5.5 · контекст 42% · неделя 41%")
        XCTAssertEqual(StatusLineInput.summaryLine(from: Data("{}".utf8), usage: nil), "S2A X-Ray")
    }
}
