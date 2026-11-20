import Foundation

/// One HTTP/1.1 request, as X-Ray's receiver needs it.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    /// Parameters of the query string, percent-decoded; "+" stays a plus sign.
    public var query: [String: String]
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

/// Minimal HTTP/1.1 request parser for the receiver: request line, headers, and a body framed by
/// `Content-Length` or chunked transfer encoding. One request per connection.
public enum HTTPRequestParser {
    public enum Result: Equatable {
        case incomplete
        case tooLarge
        case invalid
        case complete(HTTPRequest)
    }

    static let headerLimit = 64 * 1024
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let lineEnd = Data("\r\n".utf8)

    public static func parse(_ buffer: Data, maxBody: Int = 32 * 1024 * 1024) -> Result {
        guard let end = buffer.range(of: headerEnd) else {
            return buffer.count > headerLimit ? .invalid : .incomplete
        }
        guard end.lowerBound <= headerLimit,
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = end.upperBound
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch chunkedBody(buffer, from: bodyStart, maxBody: maxBody) {
            case .success(let decoded):
                guard let decoded else { return .incomplete }
                body = decoded
            case .failure(let failure):
                return failure == .tooLarge ? .tooLarge : .invalid
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return .invalid }
            guard length <= maxBody else { return .tooLarge }
            guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
            body = Data(buffer[bodyStart..<(bodyStart + length)])
        }

        var path = String(requestLine[1])
        var query: [String: String] = [:]
        if let mark = path.firstIndex(of: "?") {
            query = parseQuery(path[path.index(after: mark)...])
            path = String(path[..<mark])
        }
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers, body: body))
    }

    /// `a=1&b=x%2Fy` → ["a": "1", "b": "x/y"]; the first value of a repeated name wins.
    static func parseQuery(_ text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first.flatMap({ String($0).removingPercentEncoding }), !name.isEmpty,
                  result[name] == nil else { continue }
            result[name] = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
        }
        return result
    }

    enum ChunkError: Error { case tooLarge, invalid }

    /// The decoded body, nil while more bytes are needed.
    private static func chunkedBody(_ buffer: Data, from start: Data.Index, maxBody: Int) -> Swift.Result<Data?, ChunkError> {
        var body = Data()
        var cursor = start
        while true {
            guard let lineRange = buffer.range(of: lineEnd, in: cursor..<buffer.endIndex) else { return .success(nil) }
            guard let sizeLine = String(data: buffer[cursor..<lineRange.lowerBound], encoding: .ascii) else { return .failure(.invalid) }
            let sizeText = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return .failure(.invalid) }
            cursor = lineRange.upperBound
            if size == 0 {
                // Optional trailers end with an empty line.
                guard buffer.range(of: lineEnd, in: cursor..<buffer.endIndex) != nil else { return .success(nil) }
                return .success(body)
            }
            guard body.count + size <= maxBody else { return .failure(.tooLarge) }
            guard buffer.endIndex - cursor >= size + 2 else { return .success(nil) }
            body.append(buffer[cursor..<(cursor + size)])
            cursor += size + 2
        }
    }
}

/// Validation for transcript uploads from cloud sessions.
public enum TranscriptUpload {
    /// The lines of an upload that are JSON objects, each ending with a newline; anything else
    /// (a cut-off line, binary junk) is dropped so it cannot corrupt the stored transcript.
    public static func validLines(_ body: Data) -> (data: Data, accepted: Int, rejected: Int) {
        var output = Data()
        var accepted = 0
        var rejected = 0
        for line in body.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let trimmed = line.last == UInt8(ascii: "\r") ? line.dropLast() : line
            guard !trimmed.isEmpty else { continue }
            if (try? JSONSerialization.jsonObject(with: Data(trimmed))) is [String: Any] {
                output.append(contentsOf: trimmed)
                output.append(UInt8(ascii: "\n"))
                accepted += 1
            } else {
                rejected += 1
            }
        }
        return (output, accepted, rejected)
    }

    /// Where an upload is stored, relative to X-Ray's cloud folder: the path the session sent
    /// (relative to its `projects` folder) or `<project>/<session>.jsonl`. Nil when unsafe.
    public static func relativePath(path: String?, session: String?, project: String?) -> String? {
        if let path, !path.isEmpty {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard (1...6).contains(parts.count), parts.allSatisfy(isSafe), parts.last?.hasSuffix(".jsonl") == true else { return nil }
            return parts.joined(separator: "/")
        }
        guard let session, isSafe(session) else { return nil }
        let folder = project.flatMap { isSafe($0) ? $0 : nil } ?? "cloud"
        return "\(folder)/\(session).jsonl"
    }

    /// Letters, digits, `.`, `_` and `-`; not `.` or `..`; at most 200 characters.
    static func isSafe(_ component: String) -> Bool {
        guard !component.isEmpty, component.count <= 200, component != ".", component != ".." else { return false }
        return component.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "._-".unicodeScalars.contains(scalar)
        }
    }

    /// Compares secrets without stopping at the first difference.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}
