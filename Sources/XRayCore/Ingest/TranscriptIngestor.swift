import Foundation

/// What one scan found in one transcript folder.
public struct SourceStat: Sendable, Equatable {
    public var directory: URL
    public var exists: Bool
    /// Transcript files (`*.jsonl`) in the folder and its subfolders.
    public var files = 0
    /// When the most recently written transcript was last modified.
    public var newestModification: Date?

    public init(directory: URL, exists: Bool, files: Int = 0, newestModification: Date? = nil) {
        self.directory = directory
        self.exists = exists
        self.files = files
        self.newestModification = newestModification
    }
}

/// Result of one incremental scan.
public struct ScanResult: Sendable {
    /// Events parsed from the bytes appended since the previous scan (not yet de-duplicated).
    public var events: [UsageEvent] = []
    /// Activity trace items from recently modified transcripts.
    public var activities: [ActivityItem] = []
    public var filesSeen = 0
    public var filesRead = 0
    public var linesRead = 0
    public var errors: [String] = []
    public var duration: TimeInterval = 0
    /// Every scanned folder, in the order given, including missing ones.
    public var sources: [SourceStat] = []

    /// When any transcript was last written.
    public var newestModification: Date? {
        sources.compactMap(\.newestModification).max()
    }

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

    /// - Parameter activitySince: transcripts modified after this date are also parsed
    ///   into activity items for the live trace; `nil` skips activity parsing.
    public func scan(directories: [URL], activitySince: Date? = nil) -> ScanResult {
        let started = Date()
        var result = ScanResult()
        let fileManager = FileManager.default

        for directory in directories {
            var source = SourceStat(directory: directory, exists: ClaudeDataLocator.isDirectory(directory))
            defer { result.sources.append(source) }
            guard source.exists else { continue }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                result.errors.append("Нет доступа к \(directory.path)")
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                result.filesSeen += 1
                source.files += 1
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified > (source.newestModification ?? .distantPast) {
                    source.newestModification = modified
                }
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
                var wantsActivity = false
                if let activitySince {
                    wantsActivity = (modified ?? .distantFuture) >= activitySince
                }
                for line in lines {
                    if let event = TranscriptParser.parse(
                        line: line,
                        fallbackSessionID: sessionID,
                        fallbackProject: project
                    ) {
                        result.events.append(event)
                    }
                    if wantsActivity {
                        result.activities += ActivityParser.parse(
                            line: line,
                            fallbackSessionID: sessionID,
                            fallbackProject: project
                        )
                    }
                }
            }
        }

        result.duration = Date().timeIntervalSince(started)
        return result
    }
}
