import Foundation

/// Reads a growing append-only file line by line, remembering where it stopped.
///
/// Claude Code appends to the transcript while a session runs, so each scan
/// only reads the bytes added since the previous one. A trailing line without
/// a newline is left for the next scan unless it is already complete JSON
/// (files that ended without a final newline). Truncation or replacement of
/// the file (a different inode or a smaller size) restarts from the top.
public final class IncrementalLineReader {
    public private(set) var offset: UInt64 = 0
    private var fileNumber: UInt64?

    public init() {}

    /// Returns the complete lines appended since the last call.
    public func readNewLines(from url: URL) throws -> [Data] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value

        if number != fileNumber || size < offset {
            offset = 0
        }
        fileNumber = number
        guard size > offset else { return [] }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd(), !data.isEmpty else { return [] }

        var lines: [Data] = []
        var consumed = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var lineStart = 0
            for index in 0..<buffer.count where buffer[index] == 0x0A {
                if index > lineStart {
                    lines.append(Data(bytes: base + lineStart, count: index - lineStart))
                }
                lineStart = index + 1
            }
            consumed = lineStart
        }

        if consumed < data.count {
            let remainder = data.subdata(in: consumed..<data.count)
            if (try? JSONSerialization.jsonObject(with: remainder)) != nil {
                lines.append(remainder)
                consumed = data.count
            }
        }

        offset += UInt64(consumed)
        return lines
    }
}
