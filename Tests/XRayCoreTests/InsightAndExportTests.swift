import XCTest
@testable import XRayCore

final class InsightEngineTests: XCTestCase {
    let engine = InsightEngine(pricing: .default)

    func testGoodCacheIsReportedAsGood() {
        let events = Fixture.priced((0..<5).map { Fixture.assistantLine(id: "m\($0)", cacheRead: 500_000, write1h: 1_000) })
        let insight = engine.analyze(events).first { $0.id == "cache.hit" }
        XCTAssertEqual(insight?.severity, .good)
    }

    func testLowCacheHitRateIsAWarning() {
        let events = Fixture.priced((0..<5).map { Fixture.assistantLine(id: "m\($0)", input: 50_000, cacheRead: 1_000, write1h: 50_000) })
        let insights = engine.analyze(events)
        XCTAssertEqual(insights.first { $0.id == "cache.hit" }?.severity, .warning)
        XCTAssertNotNil(insights.first { $0.id == "cache.writes" }, "writes dominate the cost here")
        XCTAssertEqual(insights.first?.severity, .warning, "sorted by severity")
    }

    func testDetectsCacheRewarmsAfterIdleGaps() throws {
        let start = Fixture.date(2026, 11, 14, 9)
        var lines: [String] = []
        for i in 0..<4 {
            // Each request comes 2 hours after the previous one and rewrites ~100K of context.
            lines.append(Fixture.assistantLine(
                id: "r\(i)", timestamp: start.addingTimeInterval(Double(i) * 7200),
                cacheRead: 1_000, write5m: 0, write1h: 100_000, session: "s1"
            ))
        }
        let insight = try XCTUnwrap(engine.analyze(Fixture.priced(lines)).first { $0.id == "cache.rewarm" })
        XCTAssertEqual(insight.metric, "3×", "the first request has no predecessor")
        // Each rewarm writes 100K at $8/MTok (1h) instead of reading at $0.20/MTok.
        XCTAssertEqual(insight.potentialSavings ?? 0, 3 * 0.1 * (8 - 0.2), accuracy: 1e-6)
    }

    func testModelMixWhatIfOffersSonnetSavings() throws {
        let events = Fixture.priced((0..<3).map { Fixture.assistantLine(id: "o\($0)", model: "claude-opus-5-5") })
        let insight = try XCTUnwrap(engine.analyze(events).first { $0.id == "model.mix" })
        XCTAssertEqual(insight.kind, .tradeoff)
        let opus = UsageSummary.of(events).cost.total
        let sonnet = try XCTUnwrap(PricingTable.default.cost(of: events, asModel: "claude-sonnet-5-5"))
        XCTAssertEqual(insight.potentialSavings ?? 0, opus - sonnet, accuracy: 1e-9)
    }

    func testEmptyInputHasNoInsights() {
        XCTAssertTrue(engine.analyze([]).isEmpty)
    }
}

final class ReportExporterTests: XCTestCase {
    func testDailyCSV() {
        let events = Fixture.priced([
            Fixture.assistantLine(id: "a", timestamp: Fixture.date(2026, 11, 13, 10)),
            Fixture.assistantLine(id: "b", timestamp: Fixture.date(2026, 11, 14, 10), model: "claude-haiku-5-5"),
            Fixture.assistantLine(id: "c", timestamp: Fixture.date(2026, 11, 14, 11)),
        ])
        let csv = ReportExporter.dailyCSV(events, calendar: Fixture.utc)
        let rows = csv.split(separator: "\n")
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows[0].hasPrefix("date,model,requests"))
        XCTAssertTrue(rows[1].hasPrefix("2026-11-13,claude-opus-5-5,1,"))
        XCTAssertTrue(rows[2].hasPrefix("2026-11-14,claude-haiku-5-5,1,"))
    }

    func testCSVQuoting() {
        XCTAssertEqual(ReportExporter.csvField("plain"), "plain")
        XCTAssertEqual(ReportExporter.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(ReportExporter.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testMarkdownReportHasAllSections() {
        let events = Fixture.priced([Fixture.assistantLine(id: "a"), Fixture.assistantLine(id: "b", session: "s2")])
        let insights = InsightEngine(pricing: .default).analyze(events)
        let md = ReportExporter.markdown(title: "Отчёт", periodLabel: "7 дней", events: events, insights: insights)
        for heading in ["# Отчёт", "## Итого", "## По моделям", "## По проектам", "## Самые дорогие сессии", "## Оптимизация"] {
            XCTAssertTrue(md.contains(heading), "missing \(heading)")
        }
        XCTAssertTrue(md.contains("Opus 5.5"))
    }

    func testSessionsCSV() {
        let sessions = SessionAnalytics.sessions(Fixture.priced([Fixture.assistantLine(id: "a", cwd: "/Users/me/my,project")]))
        let csv = ReportExporter.sessionsCSV(sessions)
        XCTAssertTrue(csv.contains("\"/Users/me/my,project\""))
        XCTAssertEqual(csv.split(separator: "\n").count, 2)
    }
}

final class FmtTests: XCTestCase {
    func testFormatting() {
        XCTAssertEqual(Fmt.usd(0), "$0.00")
        XCTAssertEqual(Fmt.usd(0.004), "<$0.01")
        XCTAssertEqual(Fmt.usd(12.346), "$12.35")
        XCTAssertEqual(Fmt.usd(1234.4), "$1,234")
        XCTAssertEqual(Fmt.tokens(950), "950")
        XCTAssertEqual(Fmt.tokens(12_340), "12.3K")
        XCTAssertEqual(Fmt.tokens(4_560_000), "4.56M")
        XCTAssertEqual(Fmt.tokens(2_000_000), "2M")
        XCTAssertEqual(Fmt.percent(0.385), "39%")
        XCTAssertEqual(Fmt.percent(0.042), "4.2%")
        XCTAssertEqual(Fmt.duration(2 * 3600 + 5 * 60), "2 ч 05 мин")
        XCTAssertEqual(Fmt.duration(14 * 60), "14 мин")
        XCTAssertEqual(Fmt.dateTime(Fixture.date(2026, 11, 14, 7, 3), calendar: Fixture.utc), "14.11 07:03")
        XCTAssertEqual(Fmt.isoDay(Fixture.date(2026, 1, 2, 3), calendar: Fixture.utc), "2026-01-02")
        XCTAssertEqual(Fmt.shortDuration(0.85), "850 мс")
        XCTAssertEqual(Fmt.shortDuration(4.24), "4.2 с")
        XCTAssertEqual(Fmt.shortDuration(185), "3 мин 05 с")
        XCTAssertEqual(Fmt.ms(2128), "2.1 с")
        XCTAssertEqual(Fmt.bytes(820), "820 Б")
        XCTAssertEqual(Fmt.bytes(12_600), "12.3 КБ")
        XCTAssertEqual(Fmt.plural(1, "раз", "раза", "раз"), "1 раз")
        XCTAssertEqual(Fmt.plural(3, "раз", "раза", "раз"), "3 раза")
        XCTAssertEqual(Fmt.plural(12, "раз", "раза", "раз"), "12 раз")
        XCTAssertEqual(Fmt.plural(21, "событие", "события", "событий"), "21 событие")
    }
}
