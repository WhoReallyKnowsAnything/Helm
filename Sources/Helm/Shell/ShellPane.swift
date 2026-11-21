import SwiftTerm
import SwiftUI

/// Shows the folder's kept-alive shell from `ShellStore`. Leaving the pane does not stop the shell (D-06, reversed).
struct ShellPane: NSViewRepresentable {
    let folder: String
    var store: ShellStore = .shared
    /// Replaces the real process start, for tests.
    var start: ((ShellLaunch) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = store.session(for: folder, start: start).view
        view.removeFromSuperview()
        view.processDelegate = context.coordinator
        ShellAppearance.apply(to: view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    // The view already resizes the pty and sends SIGWINCH itself, so the size callbacks stay empty.
    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {}

        nonisolated func processFailedToStart(source: TerminalView, error: LocalProcessError) {
            source.feed(text: "Cannot start the shell: \(error)\r\n")
        }
    }
}
