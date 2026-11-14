import Foundation
@testable import XRayCore

/// Builds synthetic transcript lines shaped like Claude Code's JSONL.
enum Fixture {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// `2026-11-14T17:23:32.438Z`-style timestamp from components (UTC).
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func assistantLine(
        id: String = "msg_01",
        requestId: String? = "req_01",
        timestamp: Date = date(2026, 11, 14, 17, 23),
        model: String = "claude-opus-5-5",
        input: Int = 2,
        output: Int = 400,
        cacheRead: Int = 60_000,
        write5m: Int = 0,
        write1h: Int = 20_000,
        thinking: Int = 200,
        session: String = "session-a",
        cwd: String = "/Users/me/code/app",
        branch: String? = "main",
        sidechain: Bool = false,
        effort: Any? = "xhigh",
        speed: String = "standard",
        webSearches: Int = 0,
        contentType: String = "text"
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": write5m + write1h,
            "cache_creation": ["ephemeral_5m_input_tokens": write5m, "ephemeral_1h_input_tokens": write1h],
            "output_tokens_details": ["thinking_tokens": thinking],
            "server_tool_use": ["web_search_requests": webSearches, "web_fetch_requests": 0],
            "service_tier": "standard",
            "speed": speed,
            "fallback_credit": NSNull(),
        ]
        usage["inference_geo"] = "global"
        var entry: [String: Any] = [
            "type": "assistant",
            "uuid": UUID().uuidString,
            "timestamp": iso(timestamp),
            "sessionId": session,
            "cwd": cwd,
            "isSidechain": sidechain,
            "version": "2.1.325",
            "message": [
                "id": id,
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [["type": contentType]],
                "stop_reason": NSNull(),
                "usage": usage,
            ] as [String: Any],
        ]
        if let requestId { entry["requestId"] = requestId }
        if let branch { entry["gitBranch"] = branch }
        if let effort { entry["effort"] = effort }
        let data = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    static func userLine(text: String = "Привет", session: String = "session-a") -> String {
        let entry: [String: Any] = [
            "type": "user",
            "timestamp": iso(date(2026, 11, 14, 17, 20)),
            "sessionId": session,
            "message": ["role": "user", "content": text],
        ]
        let data = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    static func event(_ line: String) -> UsageEvent {
        TranscriptParser.parse(line: Data(line.utf8))!
    }

    static func priced(_ lines: [String], pricing: PricingTable = .default) -> [PricedEvent] {
        let store = UsageStore(events: lines.compactMap { TranscriptParser.parse(line: Data($0.utf8)) })
        return pricing.price(store.events)
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xray-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
