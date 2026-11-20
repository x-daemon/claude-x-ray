import Foundation
import XRayCore

/// Files X-Ray keeps in ~/Library/Application Support/S2AClaudeXRay (on the iPad, in the app's
/// own Application Support folder).
enum XRayPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? ClaudeDataLocator.home.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("S2AClaudeXRay", isDirectory: true)
    }

    /// Account plan usage last reported by Claude Code's status line.
    static var planUsage: URL { support.appendingPathComponent("plan-usage.json") }
    /// The user's own status line command that X-Ray wraps.
    static var statusLineConfig: URL { support.appendingPathComponent("statusline.json") }
    /// Imported transcripts (for example from cloud sessions); always scanned.
    static var imported: URL { support.appendingPathComponent("imported", isDirectory: true) }
    /// Transcripts that cloud sessions push to the receiver; always scanned.
    static var cloud: URL { support.appendingPathComponent("cloud", isDirectory: true) }
    /// Access token of the receiver.
    static var receiverToken: URL { support.appendingPathComponent("receiver-token") }
    /// Access token of the iPad app (read-only access to the logs), separate from the upload token.
    static var viewerToken: URL { support.appendingPathComponent("viewer-token") }
    /// The iPad's copies of the computers' transcripts, one folder per computer.
    static var mirror: URL { support.appendingPathComponent("Mirror", isDirectory: true) }
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
