import AppKit
import SwiftUI

/// The quit alerts. App-modal, so they work when no window is open (a sheet would not). Nothing is stopped here.
@MainActor
enum QuitDialog {
    private static let width = SheetWidth.small
    private static let rowHeight: CGFloat = 28
    private static let maxListHeight: CGFloat = 240

    /// True for Quit, false for Cancel. The checked flags stay set on the model for the caller.
    static func ask(model: QuitModel) -> Bool {
        makeAskAlert(model: model).runModal() == .alertFirstButtonReturn
    }

    /// The Quit prompt, built but not shown, so a test can read and lay it out without `runModal`.
    static func makeAskAlert(model: QuitModel) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quit Orchestrator GUI?"
        alert.informativeText = "Checked projects stop. Unchecked projects keep running in tmux."
        let list = NSHostingView(rootView: QuitChoices(model: model).kitAccentRoot())
        list.frame = NSRect(
            x: 0, y: 0, width: width,
            height: min(CGFloat(model.entries.count) * rowHeight + 8, maxListHeight))
        alert.accessoryView = list
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func showFailures(_ failures: [QuitFailure]) {
        makeFailureAlert(failures).runModal()
    }

    static func makeFailureAlert(_ failures: [QuitFailure]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some projects could not be stopped"
        alert.informativeText = failures.map { "\($0.title): \($0.reason)" }.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        return alert
    }
}

/// A long list scrolls instead of growing past the screen.
private struct QuitChoices: View {
    @ObservedObject var model: QuitModel
    @Environment(\.kitAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(model.entries) { entry in
                    Toggle(entry.title, isOn: Binding(
                        get: { entry.isChecked }, set: { model.setChecked(entry.id, $0) }))
                }
            }
            .kitType(.body)
            .tint(accent.fill)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.xs)
        }
    }
}
