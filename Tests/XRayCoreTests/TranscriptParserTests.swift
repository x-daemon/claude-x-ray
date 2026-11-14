import XCTest
@testable import XRayCore

final class TranscriptParserTests: XCTestCase {
    func testParsesAssistantUsage() throws {
        let line = Fixture.assistantLine(
            id: "msg_A", requestId: "req_A", model: "claude-opus-5-5",
            input: 3, output: 795, cacheRead: 190_584, write5m: 10, write1h: 509, thinking: 333,
            session: "s1", cwd: "/Users/me/code/xray", branch: "feature/x", sidechain: true,
            effort: "xhigh", speed: "fast", webSearches: 2
        )
        let event = try XCTUnwrap(TranscriptParser.parse(line: Data(line.utf8)))

        XCTAssertEqual(event.messageID, "msg_A")
        XCTAssertEqual(event.requestID, "req_A")
        XCTAssertEqual(event.dedupeKey, "msg_A|req_A")
        XCTAssertEqual(event.model, "claude-opus-5-5")
        XCTAssertEqual(event.sessionID, "s1")
        XCTAssertEqual(event.projectPath, "/Users/me/code/xray")
        XCTAssertEqual(event.projectName, "xray")
        XCTAssertEqual(event.gitBranch, "feature/x")
        XCTAssertTrue(event.isSidechain)
        XCTAssertEqual(event.effort, "xhigh")
        XCTAssertTrue(event.isFastMode)
        XCTAssertEqual(event.webSearchRequests, 2)
        XCTAssertEqual(event.tokens, TokenCounts(input: 3, output: 795, cacheRead: 190_584, cacheWrite5m: 10, cacheWrite1h: 509, thinking: 333))
        XCTAssertEqual(event.timestamp, Fixture.date(2026, 11, 14, 17, 23))
    }

    func testSkipsLinesWithoutBilledUsage() {
        XCTAssertNil(TranscriptParser.parse(line: Data(Fixture.userLine().utf8)))
        XCTAssertNil(TranscriptParser.parse(line: Data("not json at all".utf8)))
        XCTAssertNil(TranscriptParser.parse(line: Data("{\"type\":\"assistant\",\"usage\":".utf8)))
        XCTAssertNil(TranscriptParser.parse(line: Data(Fixture.assistantLine(model: "<synthetic>").utf8)))
        let zero = Fixture.assistantLine(input: 0, output: 0, cacheRead: 0, write5m: 0, write1h: 0, thinking: 0)
        XCTAssertNil(TranscriptParser.parse(line: Data(zero.utf8)))
    }

    func testToleratesUnexpectedFieldTypes() throws {
        // `effort` as an object instead of a string must not drop the whole line.
        let line = Fixture.assistantLine(effort: ["level": "high"])
        let event = try XCTUnwrap(TranscriptParser.parse(line: Data(line.utf8)))
        XCTAssertNil(event.effort)
        XCTAssertEqual(event.tokens.output, 400)
    }

    func testOldFormatWithoutCacheSplitCountsAsFiveMinuteWrites() throws {
        let line = """
        {"type":"assistant","timestamp":"2025-06-01T10:00:00Z","sessionId":"old","cwd":"/tmp/p","message":{"id":"msg_old","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}
        """
        let event = try XCTUnwrap(TranscriptParser.parse(line: Data(line.utf8)))
        XCTAssertEqual(event.tokens.cacheWrite5m, 40)
        XCTAssertEqual(event.tokens.cacheWrite1h, 0)
        XCTAssertNil(event.requestID)
        XCTAssertEqual(event.dedupeKey, "msg_old")
    }

    func testFallbacksForMissingSessionAndProject() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-01-02T03:04:05.678Z","message":{"id":"msg_x","model":"claude-haiku-5-5","usage":{"input_tokens":1,"output_tokens":2}}}
        """
        let event = try XCTUnwrap(TranscriptParser.parse(line: Data(line.utf8), fallbackSessionID: "file-session", fallbackProject: "-Users-me-proj"))
        XCTAssertEqual(event.sessionID, "file-session")
        XCTAssertEqual(event.projectPath, "-Users-me-proj")
    }
}
