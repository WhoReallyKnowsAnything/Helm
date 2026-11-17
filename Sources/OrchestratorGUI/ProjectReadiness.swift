import Foundation

/// D-04: exit 0 from the launcher is not enough. A detached start returns before the pane runs, and a failing
/// `claude` removes the session within milliseconds, so the session must stay up and its dashboard pane alive
/// for the whole wait. Reads tmux only (has-session, list-panes); it never changes tmux state.
enum ProjectReadiness {
    /// Every line of `list-panes -F '#{pane_dead}'` is `0`. A dead pane that stays needs `remain-on-exit`.
    static func paneAlive(_ output: String) -> Bool {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return !lines.isEmpty && lines.allSatisfy { $0 == "0" }
    }

    /// Not ready as soon as one poll fails; ready only when the whole wait passes.
    static func isReady(
        base: String, totalSeconds: TimeInterval = 1.5, pollSeconds: TimeInterval = 0.25, socket: String? = TmuxRunner.socket
    ) -> Bool {
        guard let tmux = OrchestratorPaths.tmuxPath() else { return false }
        let deadline = Date().addingTimeInterval(totalSeconds)
        while true {
            guard poll(tmux, base, socket) else { return false }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return true }
            Thread.sleep(forTimeInterval: min(pollSeconds, remaining))
        }
    }

    /// The exact `=` targets match `tmux_teardown_worker` in the orchestrator: a name prefix is never a target.
    private static func poll(_ tmux: String, _ base: String, _ socket: String?) -> Bool {
        let environment = TmuxRunner.environment(socket: socket)
        let session = ProcessRunner.run(
            tmux, TmuxRunner.args(["has-session", "-t", "=" + base], socket: socket), environment: environment, timeout: 5)
        guard session.status == 0, !session.timedOut, !session.failedToStart else { return false }
        let panes = ProcessRunner.run(
            tmux, TmuxRunner.args(["list-panes", "-t", "=\(base):=dashboard", "-F", "#{pane_dead}"], socket: socket),
            environment: environment, timeout: 5)
        return panes.status == 0 && !panes.timedOut && paneAlive(panes.stdout)
    }
}
