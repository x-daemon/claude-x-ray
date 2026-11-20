import Foundation
import XRayCore

/// This Mac's address in the user's tailnet, read from the Tailscale command line tool.
enum TailscaleAddress {
    static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    /// "https://<machine>.<tailnet>.ts.net", or nil without Tailscale. Runs the tool: call it off
    /// the main thread.
    static func detect() -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let data = run(path, ["status", "--json"]), let url = ViewerLink.tailscaleAddress(statusJSON: data) {
                return url.absoluteString
            }
        }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Do not wait forever when the Tailscale service does not answer.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
