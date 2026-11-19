import SwiftTerm
import SwiftUI

/// Hosts one shell session in `folder`. The shell ends when the pane is dismantled.
struct ShellPane: NSViewRepresentable {
    let folder: String
    /// Replaces the real process start, for tests.
    var start: ((ShellLaunch) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(session: ShellSession(start: start)) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let session = context.coordinator.session
        let view = session.view
        view.processDelegate = context.coordinator
        ShellAppearance.apply(to: view)
        session.start(ShellLaunch(folder: folder, parentEnvironment: ProcessInfo.processInfo.environment))
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    /// Every leave path removes the pane from the view tree, so this is the one stop point (D-06).
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.session.stop()
    }

    // The view already resizes the pty and sends SIGWINCH itself, so the size callbacks stay empty.
    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: ShellSession

        init(session: ShellSession) { self.session = session }

        nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {}

        nonisolated func processFailedToStart(source: TerminalView, error: LocalProcessError) {
            source.feed(text: "Cannot start the shell: \(error)\r\n")
        }
    }
}
