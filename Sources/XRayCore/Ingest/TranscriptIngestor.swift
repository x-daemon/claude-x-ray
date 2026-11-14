import Foundation

/// Result of one incremental scan.
public struct ScanResult: Sendable {
    /// Events parsed from the bytes appended since the previous scan (not yet de-duplicated).
    public var events: [UsageEvent] = []
    public var filesSeen = 0
    public var filesRead = 0
    public var linesRead = 0
    public var errors: [String] = []
    public var duration: TimeInterval = 0

    public init() {}
}

/// Scans transcript folders incrementally. Keeps one reader per file, so a
/// rescan after a file-system event only reads newly appended bytes.
public actor TranscriptIngestor {
    private var readers: [String: IncrementalLineReader] = [:]

    public init() {}

    /// Forgets all read positions; the next scan reads everything again.
    public func reset() {
        readers.removeAll()
    }

    public func scan(directories: [URL]) -> ScanResult {
        let started = Date()
        var result = ScanResult()
        let fileManager = FileManager.default

        for directory in directories {
            guard ClaudeDataLocator.isDirectory(directory) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                result.errors.append("Нет доступа к \(directory.path)")
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                result.filesSeen += 1
                let key = url.standardizedFileURL.path
                let reader = readers[key] ?? IncrementalLineReader()
                readers[key] = reader

                let lines: [Data]
                do {
                    lines = try reader.readNewLines(from: url)
                } catch {
                    result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                guard !lines.isEmpty else { continue }

                result.filesRead += 1
                result.linesRead += lines.count
                let sessionID = url.deletingPathExtension().lastPathComponent
                let project = url.deletingLastPathComponent().lastPathComponent
                for line in lines {
                    if let event = TranscriptParser.parse(
                        line: line,
                        fallbackSessionID: sessionID,
                        fallbackProject: project
                    ) {
                        result.events.append(event)
                    }
                }
            }
        }

        result.duration = Date().timeIntervalSince(started)
        return result
    }
}
