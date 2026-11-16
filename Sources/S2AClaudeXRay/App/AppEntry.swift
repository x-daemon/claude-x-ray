import Foundation

/// Entry point. With `--statusline` the binary acts as Claude Code's status line command and exits
/// before any UI starts; otherwise it launches the app.
@main
@MainActor
enum AppEntry {
    static func main() {
        if CommandLine.arguments.dropFirst().contains(StatusLineCommand.flag) {
            StatusLineCommand.run()
            return
        }
        S2AClaudeXRayApp.main()
    }
}
