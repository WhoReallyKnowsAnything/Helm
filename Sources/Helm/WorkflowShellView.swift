import SwiftUI

/// The live workflow shell (D-01): `WorkflowShellFrame` with the real phase list and picks. `content` supplies the screen of
/// every tab: Board, Context, Plan, Execute, Verify, Run record and Milestone.
/// It holds no store, no timer and writes no file.
struct WorkflowShellView<Content: View>: View {
    let rows: [WorkflowBoard.Row]
    let phase: String
    let tab: String
    let onPickPhase: (String) -> Void
    let onSelectTab: (String) -> Void
    /// The editor of a file link, drawn below the tab bar while the tab stays mounted (D-02 of phase 6).
    let editor: AnyView?
    /// The project hold bar, drawn above the tab content on every tab and over the editor (D-03 of phase 6).
    let holdBar: AnyView?
    let content: (String) -> Content

    init(rows: [WorkflowBoard.Row], phase: String, tab: String, onPickPhase: @escaping (String) -> Void,
         onSelectTab: @escaping (String) -> Void, editor: AnyView? = nil, holdBar: AnyView? = nil,
         @ViewBuilder content: @escaping (String) -> Content) {
        self.editor = editor
        self.holdBar = holdBar
        self.rows = rows
        self.phase = phase
        self.tab = tab
        self.onPickPhase = onPickPhase
        self.onSelectTab = onSelectTab
        self.content = content
    }

    var body: some View {
        WorkflowShellFrame(phases: rows.map { KitPhaseOption(id: $0.n, name: $0.name) }, phase: phase, tab: tab,
                           onPickPhase: onPickPhase, onSelectTab: onSelectTab, editor: editor, holdBar: holdBar) {
            content(tab)
        }
    }
}
