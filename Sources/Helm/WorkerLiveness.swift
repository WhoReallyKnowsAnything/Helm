import Foundation

/// Which windows of a project's base session still have a live process. Blocking: call it off the main actor.
enum WorkerLiveness {
    struct Window: Equatable {
        let name: String
        let pid: Int32
        let paneDead: Bool
    }

    static let format = "#{window_name}\t#{pane_pid}\t#{pane_dead}"

    static func parse(_ text: String) -> [Window] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3, let pid = Int32(parts[1]) else { return nil }
            return Window(name: String(parts[0]), pid: pid, paneDead: parts[2] != "0")
        }
    }

    /// Alive: the pane is not dead and the pid answers signal 0. EPERM means the process exists.
    static func isAlive(_ window: Window) -> Bool {
        guard !window.paneDead, window.pid > 0 else { return false }
        return kill(window.pid, 0) == 0 || errno == EPERM
    }

    /// The names of the live windows, an empty set when the session is missing, or the reason tmux could not be asked.
    /// Never an empty set on error. `=` makes the session match exact. `socket` and `tmux` are for tests.
    static func liveLabels(
        base: String, socket: String? = TmuxRunner.socket, tmux: String? = OrchestratorPaths.tmuxPath()
    ) -> Result<Set<String>, SessionCheckFailure> {
        guard let tmux else {
            return .failure(.init(reason: "tmux not found in \(OrchestratorPaths.searchPath)"))
        }
        let args = TmuxRunner.args(["list-windows", "-t", "=" + base, "-F", format], socket: socket)
        let result = ProcessRunner.run(tmux, args, environment: TmuxRunner.environment(), timeout: TmuxRunner.timeout)
        if result.status == 0, !result.timedOut {
            return .success(Set(parse(result.stdout).filter(isAlive).map(\.name)))
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.timedOut, !result.failedToStart, stderr.contains("can't find session") || TmuxRunner.isNoServer(stderr) {
            return .success([])
        }
        return .failure(.init(reason: "Could not ask tmux about \(base): \(result.timedOut ? "timed out" : stderr)"))
    }
}
