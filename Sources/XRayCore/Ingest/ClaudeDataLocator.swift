import Foundation

/// Finds the folders where Claude Code keeps its session transcripts.
public enum ClaudeDataLocator {
    /// Candidate `projects` folders, in priority order:
    /// every entry of `CLAUDE_CONFIG_DIR` (comma separated), then
    /// `~/.claude/projects` and `~/.config/claude/projects`.
    public static func candidateProjectDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = ClaudeDataLocator.home
    ) -> [URL] {
        var result: [URL] = []
        if let configured = environment["CLAUDE_CONFIG_DIR"] {
            for raw in configured.split(separator: ",") {
                let path = raw.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { continue }
                let expanded = (path as NSString).expandingTildeInPath
                result.append(URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("projects", isDirectory: true))
            }
        }
        result.append(home.appendingPathComponent(".claude/projects", isDirectory: true))
        result.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))

        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Candidates that exist on disk; falls back to `~/.claude/projects`
    /// so the UI can show where it is looking.
    public static func defaultProjectDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = ClaudeDataLocator.home
    ) -> [URL] {
        let candidates = candidateProjectDirectories(environment: environment, home: home)
        let existing = candidates.filter { isDirectory($0) }
        return existing.isEmpty ? [home.appendingPathComponent(".claude/projects", isDirectory: true)] : existing
    }

    /// The user's home folder (the app's own folder on iPadOS, which has no Claude Code logs).
    public static var home: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
