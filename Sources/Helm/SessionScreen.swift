import SwiftUI

/// One node's screen: the worker actions strip for a worker, the hold bar, then the node's conversation. The name and the
/// counts are in the top band (D-18). It takes its data and actions as parameters.
struct SessionScreen: View {
    /// The window name: the worker's label, or `dashboard` for the orchestrator.
    let target: String
    /// The strip of a worker the tree still draws. Nil for the orchestrator.
    let actionsStrip: WorkerActionsView?
    /// The failure line of the last Mark done run, shown under the strip.
    let markDoneText: String?
    /// Every pending hold and request of the project, above the conversation. Nil when nothing is pending or for a root session.
    let holdBar: ProjectHoldBarView?
    let conversation: ConversationHost

    var body: some View {
        VStack(spacing: Space.none) {
            if let actionsStrip {
                actionsStrip
                if let markDoneText {
                    KitFooterLine { Text(verbatim: markDoneText).lineLimit(1).textSelection(.enabled) }
                }
            }
            if let holdBar {
                holdBar
            }
            conversation
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.terminal)
    }
}
