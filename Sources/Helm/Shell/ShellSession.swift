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

    func start(_ launch: ShellLaunch) {
        started = true
        startStep(launch)
    }

    /// True once a real shell ran and has since ended (the user typed `exit`).
    var hasExited: Bool { started && pid != 0 && view.process?.running != true }

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
