import Foundation

/// Stops one project through the orchestrator's own teardown (D-14, D-15). The app builds no kill command:
/// it passes the folder to `dispatch-task.sh --teardown-project` and then checks that the session is gone.
enum ProjectTeardown {
    static let defaultScript = OrchestratorPaths.orchestratorRepo + "/orchestration/lib/dispatch-task.sh"
    static let timeout: TimeInterval = 30

    /// Blocks by design; callers run it off the main actor (`stopOffMain`). `script` and `library` are parameters for tests.
    static func stop(
        folder: String, sessionId: String,
        script: String = defaultScript, library: String = OrchestratorPaths.orchestratorRepo + "/orchestration/lib/tmux-session.sh",
        socket: String? = TmuxRunner.socket
    ) throws {
        guard !folder.isEmpty else { throw SessionCheckFailure(reason: "This project has no folder, so nothing was stopped.") }
        // A drifted dashboard path or a lossy slug would otherwise stop a different project.
        let derived = try ProjectSession.baseName(for: folder, library: library)
        guard derived == sessionId else {
            throw SessionCheckFailure(
                reason: "The folder \(folder) belongs to session \(derived), not \(sessionId). Nothing was stopped.")
        }
        let result = ProcessRunner.run(
            script, ["--teardown-project", folder], environment: TmuxRunner.environment(socket: socket), timeout: timeout)
        if result.timedOut || result.failedToStart || result.status != 0 {
            let detail = [result.startError ?? "", result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit code \(result.status)"
            throw SessionCheckFailure(reason: result.timedOut ? "Stopping timed out after \(Int(timeout)) seconds. \(detail)" : detail)
        }
        // Exit 0 also means "found nothing to stop", so ask tmux (read only) whether the session is really gone.
        guard let tmux = OrchestratorPaths.tmuxPath() else {
            throw SessionCheckFailure(reason: "tmux not found in \(OrchestratorPaths.searchPath)")
        }
        let check = ProcessRunner.run(
            tmux, TmuxRunner.args(["has-session", "-t", "=" + sessionId], socket: socket),
            environment: TmuxRunner.environment(socket: socket), timeout: 5)
        if check.status == 0 { throw SessionCheckFailure(reason: "The session \(sessionId) is still running.") }
        let gone = !check.timedOut && !check.failedToStart
            && (check.stderr.contains("can't find session") || TmuxRunner.isNoServer(check.stderr))
        if !gone {
            throw SessionCheckFailure(reason: "Could not confirm that \(sessionId) stopped: \(check.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func stopOffMain(folder: String, sessionId: String) async throws {
        try await Task.detached { try stop(folder: folder, sessionId: sessionId) }.value
    }
}
