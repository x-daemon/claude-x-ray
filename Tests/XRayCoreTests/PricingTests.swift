import XCTest
@testable import XRayCore

final class PricingTests: XCTestCase {
    let table = PricingTable.default

    func testLongestPrefixWins() {
        XCTAssertEqual(table.match(model: "claude-opus-5-5").price?.displayName, "Opus 5.5")
        XCTAssertEqual(table.match(model: "claude-opus-5").price?.displayName, "Opus 5")
        XCTAssertEqual(table.match(model: "claude-sonnet-5-5").price?.displayName, "Sonnet 5.5")
        XCTAssertEqual(table.match(model: "claude-fable-5-1").price?.displayName, "Fable 5.1")
        XCTAssertFalse(table.match(model: "claude-opus-5-5").isEstimated)
    }

    func testNormalisesProviderIDs() {
        XCTAssertEqual(PricingTable.normalize("us.anthropic.claude-opus-4-8-v1:0"), "claude-opus-4-8")
        XCTAssertEqual(PricingTable.normalize("claude-opus-4-5@20251101"), "claude-opus-4-5")
        XCTAssertEqual(PricingTable.normalize("claude-opus-5-5[1m]"), "claude-opus-5-5")
        XCTAssertEqual(table.match(model: "us.anthropic.claude-opus-4-8-v1:0").price?.displayName, "Opus 4.8")
    }

    func testFamilyFallbackIsFlaggedAsEstimated() {
        let match = table.match(model: "claude-sonnet-4-5-20250929")
        XCTAssertTrue(match.isEstimated)
        XCTAssertEqual(match.price?.modelPrefix, "claude-sonnet-5-5")

        let unknown = table.match(model: "gpt-something")
        XCTAssertTrue(unknown.isEstimated)
        XCTAssertNil(unknown.price)
    }

    func testCostPerTokenType() {
        let event = UsageEvent(
            messageID: "m", timestamp: Date(), model: "claude-opus-5-5", sessionID: "s", projectPath: "/p",
            tokens: TokenCounts(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000),
            webSearchRequests: 1000
        )
        let cost = table.cost(of: event)
        XCTAssertEqual(cost.input, 4, accuracy: 1e-9)
        XCTAssertEqual(cost.output, 20, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheRead, 0.20, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheWrite, 5 + 8, accuracy: 1e-9, "1.25x and 2x of input")
        XCTAssertEqual(cost.webSearch, 10, accuracy: 1e-9)
        XCTAssertEqual(cost.total, 4 + 20 + 0.20 + 13 + 10, accuracy: 1e-9)
    }

    func testFastModeAndLongContextMultipliers() {
        let fast = UsageEvent(
            messageID: "f", timestamp: Date(), model: "claude-opus-5-5", sessionID: "s", projectPath: "/p",
            speed: "fast", tokens: TokenCounts(output: 1_000_000)
        )
        XCTAssertEqual(table.cost(of: fast).total, 40, accuracy: 1e-9)

        let longHaiku = UsageEvent(
            messageID: "h", timestamp: Date(), model: "claude-haiku-5-5", sessionID: "s", projectPath: "/p",
            tokens: TokenCounts(input: 200_000, output: 1_000_000)
        )
        // Above 100K prompt tokens every Haiku 5.5 rate is 5x: $0.50 in / $2.50 out per MTok.
        XCTAssertEqual(table.cost(of: longHaiku).total, 0.2 * 0.5 + 2.5, accuracy: 1e-9)
    }

    func testWhatIfOnAnotherModel() {
        let priced = Fixture.priced([Fixture.assistantLine(id: "a", input: 0, output: 1_000_000, cacheRead: 0, write5m: 0, write1h: 0, thinking: 0)])
        XCTAssertEqual(priced.first?.cost.total ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(table.cost(of: priced, asModel: "claude-sonnet-5-5") ?? 0, 10, accuracy: 1e-9)
        XCTAssertNil(table.cost(of: priced, asModel: "claude-nope"))
    }

    func testMergingMissingDefaultsKeepsUserEdits() {
        var saved = PricingTable(models: [ModelPrice(modelPrefix: "claude-opus-5-5", displayName: "Opus 5.5", input: 99, output: 99, cacheRead: 9)])
        saved = saved.mergingMissingDefaults()
        XCTAssertEqual(saved.models.first { $0.modelPrefix == "claude-opus-5-5" }?.input, 99)
        XCTAssertEqual(saved.models.count, PricingTable.default.models.count)
    }

    func testPricingTableRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(table)
        XCTAssertEqual(try JSONDecoder().decode(PricingTable.self, from: data), table)
    }

    func testDisplayNames() {
        XCTAssertEqual(ModelCatalog.displayName(for: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelCatalog.displayName(for: "claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(ModelCatalog.displayName(for: "claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(ModelCatalog.displayName(for: "claude-haiku-5-5"), "Haiku 5.5")
        XCTAssertEqual(ModelCatalog.family(of: "claude-mythos-5-2"), .mythos)
        XCTAssertEqual(ModelCatalog.family(of: "whatever"), .other)
        XCTAssertEqual(ModelCatalog.contextWindow(for: "claude-opus-5-5"), 1_000_000)
        XCTAssertEqual(ModelCatalog.contextWindow(for: "claude-sonnet-5-5"), 1_000_000)
        XCTAssertEqual(ModelCatalog.contextWindow(for: "claude-haiku-4-5"), 200_000)
        XCTAssertEqual(ModelCatalog.contextWindow(for: "claude-sonnet-4-5-20250929[1m]"), 1_000_000)
    }
}
