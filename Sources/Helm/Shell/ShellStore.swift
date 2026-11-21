import Foundation

/// Keeps one shell per folder (Home or a project) alive while its pane is off screen (D-06, reversed).
/// A shell stops on clear, on project close, and on quit.
@MainActor
final class ShellStore {
    static let shared = ShellStore()

    private var sessions: [String: ShellSession] = [:]

    /// The folder's live session. Starts one when none exists or the shell has exited.
    /// `start` replaces the real process start, for tests.
    func session(for folder: String, start: ((ShellLaunch) -> Void)? = nil) -> ShellSession {
        if let existing = sessions[folder], !existing.hasExited { return existing }
        let session = ShellSession(start: start)
        session.start(ShellLaunch(folder: folder, parentEnvironment: ProcessInfo.processInfo.environment))
        sessions[folder] = session
        return session
    }

    /// Ends the folder's shell. The next `session(for:)` starts a fresh one.
    func close(_ folder: String) {
        sessions.removeValue(forKey: folder)?.stop()
    }

    /// Quit path (D-07): stop every shell and wait at most 1 second in all, then SIGKILL, so quit never hangs.
    func stopAll() {
        let live = sessions.values.filter { $0.view.process?.running == true }
        sessions = [:]
        let running = live.compactMap(\.view.process)
        let pids = running.map(\.shellPid)
        live.forEach { $0.view.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while running.contains(where: \.running), Date() < deadline { usleep(20_000) }
        for (process, pid) in zip(running, pids) where process.running { kill(pid, SIGKILL) }
    }
}
