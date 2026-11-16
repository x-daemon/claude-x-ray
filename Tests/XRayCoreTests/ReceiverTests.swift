import XCTest
@testable import XRayCore

final class HTTPRequestParserTests: XCTestCase {
    private func request(_ text: String) -> Data { Data(text.utf8) }

    func testContentLengthBody() {
        let raw = request("POST /v1/transcript?x=1 HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer t\r\nContent-Length: 5\r\n\r\nhello")
        XCTAssertEqual(HTTPRequestParser.parse(raw), .complete(HTTPRequest(
            method: "POST", path: "/v1/transcript",
            headers: ["host": "a", "authorization": "Bearer t", "content-length": "5"],
            body: Data("hello".utf8)
        )))
    }

    func testIncompleteUntilTheWholeBodyArrives() {
        XCTAssertEqual(HTTPRequestParser.parse(request("POST / HTTP/1.1\r\nContent-Length: 5\r\n")), .incomplete)
        XCTAssertEqual(HTTPRequestParser.parse(request("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel")), .incomplete)
    }

    func testChunkedBody() {
        let raw = request("POST /v1/transcript HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n6;ext=1\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\n\r\n")
        guard case .complete(let parsed) = HTTPRequestParser.parse(raw) else { return XCTFail("not complete") }
        XCTAssertEqual(String(data: parsed.body, encoding: .utf8), "Wikipedia in \r\n\r\nchunks.")
        let partial = request("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWi")
        XCTAssertEqual(HTTPRequestParser.parse(partial), .incomplete)
    }

    func testLimits() {
        XCTAssertEqual(HTTPRequestParser.parse(request("POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\n"), maxBody: 10), .tooLarge)
        XCTAssertEqual(HTTPRequestParser.parse(request("garbage\r\n\r\n")), .invalid)
        XCTAssertEqual(HTTPRequestParser.parse(request("GET / HTTP/1.1\r\nbroken header\r\n\r\n")), .invalid)
        XCTAssertEqual(HTTPRequestParser.parse(Data(repeating: 65, count: HTTPRequestParser.headerLimit + 1)), .invalid)
    }
}

final class TranscriptUploadTests: XCTestCase {
    func testKeepsOnlyJSONObjectLines() {
        let body = Data("{\"type\":\"user\"}\r\nnot json\n\n[1,2]\n{\"type\":\"assistant\",\"x\":1}\n{\"cut".utf8)
        let result = TranscriptUpload.validLines(body)
        XCTAssertEqual(String(data: result.data, encoding: .utf8), "{\"type\":\"user\"}\n{\"type\":\"assistant\",\"x\":1}\n")
        XCTAssertEqual(result.accepted, 2)
        XCTAssertEqual(result.rejected, 3)
    }

    func testRelativePaths() {
        XCTAssertEqual(TranscriptUpload.relativePath(path: "-home-user/abc.jsonl", session: nil, project: nil), "-home-user/abc.jsonl")
        XCTAssertEqual(TranscriptUpload.relativePath(path: "-home-user/abc/subagents/agent-1.jsonl", session: "abc", project: nil), "-home-user/abc/subagents/agent-1.jsonl")
        XCTAssertNil(TranscriptUpload.relativePath(path: "../etc/passwd.jsonl", session: nil, project: nil))
        XCTAssertNil(TranscriptUpload.relativePath(path: "-home-user/abc.txt", session: nil, project: nil))
        XCTAssertNil(TranscriptUpload.relativePath(path: "a/b c/d.jsonl", session: nil, project: nil))
        XCTAssertEqual(TranscriptUpload.relativePath(path: nil, session: "s-1", project: "-home-user"), "-home-user/s-1.jsonl")
        XCTAssertEqual(TranscriptUpload.relativePath(path: nil, session: "s-1", project: "bad/../x"), "cloud/s-1.jsonl")
        XCTAssertNil(TranscriptUpload.relativePath(path: nil, session: "../s", project: nil))
        XCTAssertNil(TranscriptUpload.relativePath(path: nil, session: nil, project: "p"))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(TranscriptUpload.constantTimeEquals("Bearer abc", "Bearer abc"))
        XCTAssertFalse(TranscriptUpload.constantTimeEquals("Bearer abc", "Bearer abd"))
        XCTAssertFalse(TranscriptUpload.constantTimeEquals("Bearer abc", "Bearer abcd"))
        XCTAssertFalse(TranscriptUpload.constantTimeEquals("", "x"))
    }
}
