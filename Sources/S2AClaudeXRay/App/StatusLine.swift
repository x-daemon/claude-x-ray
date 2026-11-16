import Foundation
import XRayCore

/// Files X-Ray keeps in ~/Library/Application Support/S2AClaudeXRay.
enum XRayPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("S2AClaudeXRay", isDirectory: true)
    }

    /// Account plan usage last reported by Claude Code's status line.
    static var planUsage: URL { support.appendingPathComponent("plan-usage.json") }
    /// The user's own status line command that X-Ray wraps.
    static var statusLineConfig: URL { support.appendingPathComponent("statusline.json") }
    /// Imported transcripts (for example from cloud sessions); always scanned.
    static var imported: URL { support.appendingPathComponent("imported", isDirectory: true) }
}

enum PlanUsageFile {
    static func load() -> PlanUsage? {
        (try? Data(contentsOf: XRayPaths.planUsage)).flatMap(PlanUsage.decode)
    }

    static func save(_ usage: PlanUsage) {
        try? FileManager.default.createDirectory(at: XRayPaths.support, withIntermediateDirectories: true)
        if let data = try? usage.encoded() {
            try? data.write(to: XRayPaths.planUsage, options: .atomic)
        }
    }
}

/// What X-Ray changed in Claude Code's settings, so it can be undone.
struct StatusLineConfig: Codable {
    /// The status line command the user had before; X-Ray runs it and shows its output.
    var wrappedCommand: String?
    var installedAt: Date

    static func load() -> StatusLineConfig? {
        guard let data = try? Data(contentsOf: XRayPaths.statusLineConfig) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StatusLineConfig.self, from: data)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: XRayPaths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: XRayPaths.statusLineConfig, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: XRayPaths.statusLineConfig)
    }
}

/// `S2AClaudeXRay --statusline`. Claude Code runs it as its status line command after every
/// response and passes session data, including the account's plan usage, on stdin. It saves the
/// plan usage for the app and prints a status line, or the output of the user's own status line.
enum StatusLineCommand {
    static let flag = "--statusline"

    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let now = Date()
        var usage = PlanUsageFile.load()
        if let fresh = StatusLineInput.planUsage(from: input, capturedAt: now) {
            let merged = fresh.merged(with: usage)
            PlanUsageFile.save(merged)
            usage = merged
        }
        if let command = StatusLineConfig.load()?.wrappedCommand, !command.isEmpty {
            FileHandle.standardOutput.write(runWrapped(command, input: input))
        } else {
            print(StatusLineInput.summaryLine(from: input, usage: usage, now: now))
        }
    }

    /// Runs the user's status line command with the same input, the way Claude Code would.
    private static func runWrapped(_ command: String, input: Data) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            return Data()
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return output
    }
}

/// Adds X-Ray to the status line in Claude Code's settings.json. A status line the user already
/// has is kept: X-Ray runs it and shows its output. Removing restores it.
enum StatusLineInstaller {
    enum State: Equatable {
        case notInstalled
        /// The user has their own status line; connecting keeps it.
        case otherStatusLine(String)
        case installed(wrapping: String?)
        /// settings.json exists but cannot be read as JSON; X-Ray leaves it alone.
        case unreadable(String)
    }

    enum InstallError: LocalizedError {
        case notAnObject

        var errorDescription: String? {
            "settings.json не похож на настройки Claude Code (ожидался JSON-объект). X-Ray его не меняет."
        }
    }

    /// Claude Code's user settings: in `CLAUDE_CONFIG_DIR` when set, otherwise ~/.claude.
    static var settingsURL: URL {
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.split(separator: ",").first {
            let path = (String(configured).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("settings.json")
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var backupURL: URL {
        settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.xray-backup")
    }

    /// The command Claude Code runs: this app's binary with `--statusline`.
    static var command: String {
        let path = Bundle.main.executablePath ?? "/Applications/S2A Claude X-Ray.app/Contents/MacOS/S2AClaudeXRay"
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' " + StatusLineCommand.flag
    }

    static func isOurs(_ command: String) -> Bool {
        command.contains("S2AClaudeXRay") && command.contains(StatusLineCommand.flag)
    }

    static func state() -> State {
        let settings: [String: Any]
        do {
            settings = try readSettings()
        } catch {
            return .unreadable(error.localizedDescription)
        }
        guard let statusLine = settings["statusLine"] as? [String: Any],
              let current = statusLine["command"] as? String,
              !current.isEmpty else { return .notInstalled }
        if isOurs(current) {
            return .installed(wrapping: StatusLineConfig.load()?.wrappedCommand)
        }
        return .otherStatusLine(current)
    }

    static func install() throws {
        var settings = try readSettings()
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        var wrapped = StatusLineConfig.load()?.wrappedCommand
        if let current = statusLine["command"] as? String, !current.isEmpty, !isOurs(current) {
            wrapped = current
        }
        try StatusLineConfig(wrappedCommand: wrapped, installedAt: Date()).save()
        statusLine["type"] = "command"
        statusLine["command"] = command
        settings["statusLine"] = statusLine
        try writeSettings(settings)
    }

    static func uninstall() throws {
        var settings = try readSettings()
        if var statusLine = settings["statusLine"] as? [String: Any],
           let current = statusLine["command"] as? String,
           isOurs(current) {
            if let wrapped = StatusLineConfig.load()?.wrappedCommand, !wrapped.isEmpty {
                statusLine["command"] = wrapped
                settings["statusLine"] = statusLine
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            try writeSettings(settings)
        }
        StatusLineConfig.remove()
    }

    private static func readSettings() throws -> [String: Any] {
        let url = settingsURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return [:]
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.notAnObject
        }
        return object
    }

    /// Writes settings.json after copying the current one to settings.json.xray-backup.
    private static func writeSettings(_ settings: [String: Any]) throws {
        let url = settingsURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: url, to: backupURL)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
