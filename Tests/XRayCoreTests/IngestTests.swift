import XCTest
@testable import XRayCore

final class UsageStoreTests: XCTestCase {
    func testDeduplicatesOneLinePerContentBlock() {
        // Claude Code writes the same response once per content block (thinking, tool_use, ...).
        let lines = ["thinking", "tool_use", "tool_use"].map {
            Fixture.assistantLine(id: "msg_dup", requestId: "req_dup", contentType: $0)
        }
        let store = UsageStore(events: lines.map(Fixture.event))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.events.first?.tokens.output, 400)
    }

    func testKeepsTheCopyWithTheLargerOutput() {
        var store = UsageStore()
        store.merge([Fixture.event(Fixture.assistantLine(id: "m", output: 10))])
        let changed = store.merge([Fixture.event(Fixture.assistantLine(id: "m", output: 900))])
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(store.events.map(\.tokens.output), [900])
        XCTAssertEqual(store.merge([Fixture.event(Fixture.assistantLine(id: "m", output: 5))]), 0)
    }

    func testSortsOutOfOrderEvents() {
        let late = Fixture.event(Fixture.assistantLine(id: "late", timestamp: Fixture.date(2026, 11, 14, 18)))
        let early = Fixture.event(Fixture.assistantLine(id: "early", timestamp: Fixture.date(2026, 11, 14, 9)))
        var store = UsageStore()
        store.merge([late])
        store.merge([early])
        XCTAssertEqual(store.events.map(\.messageID), ["early", "late"])
        // The index must follow the re-sort: a duplicate of "late" is still recognised.
        XCTAssertEqual(store.merge([late]), 0)
        XCTAssertEqual(store.count, 2)
    }
}

final class IncrementalLineReaderTests: XCTestCase {
    func testReadsOnlyAppendedCompleteLines() throws {
        let dir = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        try Data("{\"a\":1}\n{\"b\":2}\n{\"c\":".utf8).write(to: file)

        let reader = IncrementalLineReader()
        XCTAssertEqual(try reader.readNewLines(from: file).count, 2)
        XCTAssertEqual(try reader.readNewLines(from: file).count, 0, "partial line must wait")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("3}\n{\"d\":4}\n".utf8))
        try handle.close()

        let lines = try reader.readNewLines(from: file)
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"c\":3}", "{\"d\":4}"])
    }

    func testConsumesCompleteTrailingLineWithoutNewline() throws {
        let dir = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        try Data("{\"a\":1}\n{\"b\":2}".utf8).write(to: file)

        let reader = IncrementalLineReader()
        XCTAssertEqual(try reader.readNewLines(from: file).count, 2)
        XCTAssertEqual(try reader.readNewLines(from: file).count, 0)
    }

    func testRestartsWhenFileIsTruncated() throws {
        let dir = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        try Data("{\"a\":1}\n{\"b\":2}\n".utf8).write(to: file)

        let reader = IncrementalLineReader()
        XCTAssertEqual(try reader.readNewLines(from: file).count, 2)
        try Data("{\"z\":0}\n".utf8).write(to: file)
        XCTAssertEqual(try reader.readNewLines(from: file).count, 1)
    }
}

final class TranscriptIngestorTests: XCTestCase {
    func testScansProjectFoldersIncrementally() async throws {
        let root = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-Users-me-code-app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session-a.jsonl")
        let initial = [
            Fixture.userLine(),
            Fixture.assistantLine(id: "m1", contentType: "thinking"),
            Fixture.assistantLine(id: "m1", contentType: "tool_use"),
            Fixture.assistantLine(id: "m2"),
        ].joined(separator: "\n") + "\n"
        try Data(initial.utf8).write(to: file)
        try Data("ignored".utf8).write(to: project.appendingPathComponent("notes.txt"))

        let ingestor = TranscriptIngestor()
        let first = await ingestor.scan(directories: [root])
        XCTAssertEqual(first.filesSeen, 1)
        XCTAssertEqual(first.events.count, 3, "raw events before de-duplication")
        XCTAssertEqual(UsageStore(events: first.events).count, 2)

        let second = await ingestor.scan(directories: [root])
        XCTAssertEqual(second.events.count, 0)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Fixture.assistantLine(id: "m3") + "\n").utf8))
        try handle.close()

        let third = await ingestor.scan(directories: [root])
        XCTAssertEqual(third.events.map(\.messageID), ["m3"])

        await ingestor.reset()
        let full = await ingestor.scan(directories: [root])
        XCTAssertEqual(UsageStore(events: full.events).count, 3)
    }

    func testIgnoresMissingDirectories() async {
        let result = await TranscriptIngestor().scan(directories: [URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")])
        XCTAssertEqual(result.filesSeen, 0)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testLocatorHonoursClaudeConfigDir() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let dirs = ClaudeDataLocator.candidateProjectDirectories(
            environment: ["CLAUDE_CONFIG_DIR": "/opt/claude, /Users/me/.claude"],
            home: home
        )
        XCTAssertEqual(dirs.map(\.path), [
            "/opt/claude/projects",
            "/Users/me/.claude/projects",
            "/Users/me/.config/claude/projects",
        ])
    }
}
