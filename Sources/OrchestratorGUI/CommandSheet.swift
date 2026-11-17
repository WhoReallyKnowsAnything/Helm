import SwiftUI

/// The per-session sheet for one native command (D-10). Live passes the init data so later plans fill their cases.
struct CommandSheet: View {
    let command: SlashMenu.Native
    var cwd = ""
    var sessionId: String?
    var mcpServers: [McpServer] = []
    /// True once an `mcp_status` request went out for this session; the empty list then reads as loading.
    var mcpLoading = false
    /// Restarts the session on a past conversation id; nil for a session that cannot resume (a worker).
    var relaunch: (@MainActor (String) async throws -> Void)?
    /// The folder that holds `.claude/settings.json` and `.claude/projects`; tests pass a temp folder (D-01).
    var home = NSHomeDirectory()
    /// Runs `claude auth`; tests pass a fake so no process starts.
    var authRunner: AuthFlow.Runner = AuthFlow.claude
    let onClose: () -> Void
    @State private var failure: String?
    @State private var progress: String?

    var body: some View {
        KitSheetFrame(title: "/" + command.rawValue, width: SheetWidth.medium, failure: failure, progress: progress,
                      cancelTitle: "Close", cancel: onClose) {
            switch command {
            case .permissions: PermissionsSheet(cwd: cwd, home: home, failure: $failure)
            case .config: ConfigSheet(home: home, failure: $failure)
            case .resume:
                ResumeSheet(cwd: cwd, sessionId: sessionId, projects: home + "/.claude/projects", relaunch: relaunch,
                            failure: $failure, progress: $progress, onDone: onClose)
            case .mcp: McpSheet(servers: mcpServers, loading: mcpLoading)
            case .login, .logout, .status: AuthSheet(mode: command, run: authRunner, failure: $failure, progress: $progress)
            }
        }
    }
}
