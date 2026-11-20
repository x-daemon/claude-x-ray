import Foundation

/// One transcript that X-Ray on a computer offers to the iPad app.
public struct CatalogFile: Codable, Equatable, Hashable, Sendable {
    /// Path-safe name, "<root>/<folders>/<file>.jsonl": letters, digits, ".", "_" and "-" between
    /// the slashes. The iPad stores its copy under this name.
    public var id: String
    public var size: Int64
    /// Last change, in seconds since 1970 on the computer's clock.
    public var modified: Double

    public init(id: String, size: Int64, modified: Double) {
        self.id = id
        self.size = size
        self.modified = modified
    }
}

/// `GET /v1/files`: the transcripts, and the computer's clock for the next `since`.
public struct CatalogListing: Codable, Equatable, Sendable {
    public var files: [CatalogFile]
    public var now: Double

    public init(files: [CatalogFile], now: Double) {
        self.files = files
        self.now = now
    }
}

/// `GET /v1/info`: what the iPad shows about a computer.
public struct ViewerInfo: Codable, Equatable, Sendable {
    public var app: String
    public var version: String
    /// "macOS" or "Windows".
    public var platform: String
    /// The computer's name, for example "MacBook Pro".
    public var name: String
    public var files: Int
    public var bytes: Int64
    /// When the newest transcript was written, seconds since 1970.
    public var newest: Double?
    public var planUsage: Bool

    public init(app: String = "S2A Claude X-Ray", version: String, platform: String, name: String, files: Int, bytes: Int64, newest: Double?, planUsage: Bool) {
        self.app = app
        self.version = version
        self.platform = platform
        self.name = name
        self.files = files
        self.bytes = bytes
        self.newest = newest
        self.planUsage = planUsage
    }
}

/// The transcripts in X-Ray's folders, listed for the iPad app and found again by id. An id is a
/// name X-Ray hands out, never a path it is given: a request can only reach a file it listed.
public struct TranscriptCatalog: Sendable {
    /// A scanned folder and the first part of the ids of the files in it.
    public struct Root: Equatable, Sendable {
        public var key: String
        public var url: URL

        public init(key: String, url: URL) {
            self.key = key
            self.url = url
        }
    }

    /// Newest first.
    public private(set) var files: [CatalogFile] = []
    private var urls: [String: URL] = [:]

    public init(roots: [Root], fileManager: FileManager = .default) {
        var found: [(file: CatalogFile, url: URL)] = []
        for root in roots {
            let base = root.url.standardizedFileURL
            guard let enumerator = fileManager.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      let relative = Self.relativeComponents(of: url, in: base), !relative.isEmpty else { continue }
                var id = ([root.key] + relative.map(Self.safeComponent)).joined(separator: "/")
                if urls[id] != nil {
                    // Two names that differ only in characters an id cannot hold.
                    var number = 2
                    let stem = String(id.dropLast(".jsonl".count))
                    while urls["\(stem)_\(number).jsonl"] != nil { number += 1 }
                    id = "\(stem)_\(number).jsonl"
                }
                let file = CatalogFile(
                    id: id,
                    size: Int64(values.fileSize ?? 0),
                    modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                )
                urls[id] = url
                found.append((file, url))
            }
        }
        files = found.map { $0.file }.sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified }
    }

    /// The file listed under this id; nil for anything X-Ray did not list.
    public func url(for id: String) -> URL? {
        urls[id]
    }

    /// Files changed at or after `since` (seconds since 1970); all of them without it.
    public func files(since: Double?) -> [CatalogFile] {
        guard let since else { return files }
        return files.filter { $0.modified >= since }
    }

    /// Ids start with "cloud" and "imported" for X-Ray's own folders and "local-<hash of the path>"
    /// for Claude Code's folders, so they stay the same when the folder list changes.
    public static func roots(directories: [URL], cloud: URL, imported: URL) -> [Root] {
        var result: [Root] = []
        var seen = Set<String>()
        for url in directories {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            let key: String
            if path == cloud.standardizedFileURL.path {
                key = "cloud"
            } else if path == imported.standardizedFileURL.path {
                key = "imported"
            } else {
                key = "local-" + shortHash(path)
            }
            result.append(Root(key: key, url: url))
        }
        return result
    }

    /// A file or folder name as an id holds it: other characters become "_", at most 120 of them.
    public static func safeComponent(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let safe = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
            scalars.append(safe ? scalar : "_")
        }
        var result = String(scalars)
        if result.count > 120 {
            // Keep the extension: ".jsonl" marks a transcript.
            let ext = (result as NSString).pathExtension
            result = String(result.prefix(110)) + (ext.isEmpty ? "" : "." + ext)
        }
        if result.isEmpty || result == "." || result == ".." {
            return "_"
        }
        return result
    }

    /// The names of an id's parts, for the iPad's copy; nil for an id X-Ray would not hand out, so
    /// that a server which is not X-Ray cannot make the iPad write outside its folder.
    public static func components(of id: String) -> [String]? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2...12).contains(parts.count), id.hasSuffix(".jsonl"),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 128 && safeComponent($0) == $0 && $0 != "." && $0 != ".." }) else { return nil }
        return parts
    }

    static func relativeComponents(of url: URL, in root: URL) -> [String]? {
        let file = url.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        if file.starts(with: base) { return Array(file.dropFirst(base.count)) }
        let resolvedFile = url.resolvingSymlinksInPath().pathComponents
        let resolvedBase = root.resolvingSymlinksInPath().pathComponents
        if resolvedFile.starts(with: resolvedBase) { return Array(resolvedFile.dropFirst(resolvedBase.count)) }
        return nil
    }

    /// FNV-1a of the text, folded to 32 bits, as 8 hex digits.
    static func shortHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let folded = UInt32(truncatingIfNeeded: hash ^ (hash >> 32))
        return String(format: "%08x", folded)
    }
}

/// What the iPad has to download to bring its copies up to date.
public enum MirrorPlan {
    public struct Fetch: Equatable, Sendable {
        public var file: CatalogFile
        /// Where to continue; 0 when the copy has to be replaced.
        public var from: Int64
        /// The copy is longer than the original, so the original was replaced: start again.
        public var restart: Bool
    }

    /// Files changed since `cutoff` whose copy is missing or differs in length, newest first.
    /// - Parameter local: sizes of the copies the iPad has, by id.
    public static func fetches(remote: [CatalogFile], local: [String: Int64], cutoff: Double?) -> [Fetch] {
        var result: [Fetch] = []
        for file in remote where TranscriptCatalog.components(of: file.id) != nil {
            let have = local[file.id]
            if have == nil, let cutoff, file.modified < cutoff { continue }
            let size = have ?? 0
            if size == file.size { continue }
            result.append(size > file.size ? Fetch(file: file, from: 0, restart: true) : Fetch(file: file, from: size, restart: false))
        }
        return result.sorted { $0.file.modified == $1.file.modified ? $0.file.id < $1.file.id : $0.file.modified > $1.file.modified }
    }
}
