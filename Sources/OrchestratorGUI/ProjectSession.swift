import Foundation

/// Who holds a tmux session name (D-10).
enum SessionClaim: Equatable {
    case free
    /// A `dashboard` window already runs in the expected folder.
    case sameProject
    /// Another folder, or a session with no `dashboard` window. Carries who holds the name.
    case inUse(String)

    var inUseText: String? {
        if case .inUse(let other) = self { return "name already in use by \(other)" }
        return nil
    }
}

struct SessionCheckFailure: Error, LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

struct SessionWindow: Equatable {
    let name: String
    let path: String
}

/// The tmux base session name for a folder, and who holds it. The name is the orchestrator's lossy slug of the
/// folder name, and a linked worktree is named after its main repository, so it is asked for, never rebuilt here.
/// Plan 2 reuses `baseName` to map a project to its session.
enum ProjectSession {
    /// Library path and folder arrive as $1 and $2, never spliced into this text (as `OrchestratorPaths`).
    static let nameScript = """
    source "$1" || exit 1
    tmux_base_session_name "$2"
    """

    static func baseName(
        for folder: String, library: String = OrchestratorPaths.orchestratorRepo + "/orchestration/lib/tmux-session.sh"
    ) throws -> String {
        let result = ProcessRunner.run(
            "/bin/bash", ["-c", nameScript, "bash", library, folder],
            environment: TmuxRunner.environment(), timeout: 10)
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !result.timedOut, !result.failedToStart, !name.isEmpty else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SessionCheckFailure(reason: name.isEmpty && result.status == 0
                ? "The orchestrator gave no session name for \(folder)."
                : "Could not get the session name for \(folder). \(detail)")
        }
        return name
    }

    /// The folder the launcher starts the session in: the folder itself, or the main repository of a linked
    /// worktree (the git dir differs from the git common dir, the same signal the orchestrator uses).
    static func expectedFolder(_ folder: String) -> String {
        let result = FolderCheck.runGit(["-C", folder, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"])
        let lines = result.stdout.split(separator: "\n").map(String.init)
        guard result.status == 0, lines.count == 2, lines[0] != lines[1] else { return FolderCheck.realPath(folder) }
        return FolderCheck.realPath((lines[1] as NSString).deletingLastPathComponent)
    }

    /// Pure. `windows` is nil when the session does not exist.
    static func classify(windows: [SessionWindow]?, expected: String) -> SessionClaim {
        guard let windows else { return .free }
        guard let dashboard = windows.first(where: { $0.name == "dashboard" }) else {
            return .inUse("a session with no dashboard window")
        }
        return FolderCheck.realPath(dashboard.path) == FolderCheck.realPath(expected) ? .sameProject : .inUse(dashboard.path)
    }

    static func parseWindows(_ text: String) -> [SessionWindow] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? SessionWindow(name: String(parts[0]), path: String(parts[1])) : nil
        }
    }

    /// Asks tmux now. The `=` makes the match exact, never a prefix. `socket` is for tests (`-L`).
    static func liveWindows(base: String, socket: String? = TmuxRunner.socket) throws -> [SessionWindow]? {
        guard let tmux = OrchestratorPaths.tmuxPath() else {
            throw SessionCheckFailure(reason: "tmux not found in \(OrchestratorPaths.searchPath)")
        }
        let args = TmuxRunner.args(
            ["list-windows", "-t", "=" + base, "-F", "#{window_name}\t#{pane_current_path}"], socket: socket)
        let result = ProcessRunner.run(tmux, args, environment: TmuxRunner.environment(), timeout: 5)
        if result.status == 0, !result.timedOut { return parseWindows(result.stdout) }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.timedOut, !result.failedToStart, stderr.contains("can't find session") || TmuxRunner.isNoServer(stderr) {
            return nil
        }
        throw SessionCheckFailure(reason: "Could not ask tmux about \(base): \(result.timedOut ? "timed out" : stderr)")
    }

    static func claim(base: String, folder: String, socket: String? = TmuxRunner.socket) throws -> SessionClaim {
        classify(windows: try liveWindows(base: base, socket: socket), expected: expectedFolder(folder))
    }
}
