import Foundation
import SwiftTerm

/// Owns the terminal view and the child shell of one screen. No tmux, no `SessionStore` (D-08).
@MainActor
final class ShellSession {
    let view: LocalProcessTerminalView
    private let startStep: (ShellLaunch) -> Void
    private var started = false

    /// `start` replaces the real process start, so a test checks the launch without forking (D-14).
    init(start: ((ShellLaunch) -> Void)? = nil) {
        let view = ShellKeyView(frame: .zero)
        self.view = view
        self.startStep = start ?? { launch in
            view.startProcess(executable: launch.executable, args: launch.arguments,
                              environment: launch.environment, currentDirectory: launch.folder)
        }
    }

    /// The child pid, or 0 before a real start.
    var pid: pid_t { view.process?.shellPid ?? 0 }

    /// The one shell that may run (D-06). Weak, so a dismantled pane frees its session.
    private(set) static weak var live: ShellSession?

    func start(_ launch: ShellLaunch) {
        // SwiftUI can build the replacement pane before it dismantles the old one.
        if let previous = Self.live, previous !== self { previous.stop() }
        Self.live = self
        started = true
        startStep(launch)
    }

    /// Quit path (D-07): stop the live shell and wait at most 1 second, then SIGKILL, so quit never hangs.
    static func stopLive() {
        guard let session = live, let process = session.view.process, process.running else { return }
        let pid = process.shellPid
        session.view.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.running, Date() < deadline { usleep(20_000) }
        if process.running { kill(pid, SIGKILL) }
    }

    /// SIGTERM, then SIGKILL after a short wait: an interactive shell can ignore SIGTERM.
    /// Safe to call twice and when nothing started.
    func stop() {
        guard started, let process = view.process, process.running else { return }
        let pid = process.shellPid
        view.terminate()
        Task { @MainActor [weak process] in
            try? await Task.sleep(for: .seconds(1))
            if let process, process.running, process.shellPid == pid { kill(pid, SIGKILL) }
        }
    }
}
