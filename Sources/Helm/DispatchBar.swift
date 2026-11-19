import SwiftUI

/// The bar above the tree or a terminal. Back comes first and shows only on the terminal screen, even when the project
/// has no folder (D-02). Close needs the folder, so without it the bar holds Back alone. Dispatch lives in `DispatchPromptBar`.
struct DispatchBar: View {
    let showsBack: Bool
    let showsActions: Bool
    /// The counts of waiting and running nodes, from the same tree the cards use (D-13a point 3).
    var waiting = 0
    var running = 0
    /// The open terminal's session name, drawn after Back and Close (D-18). Nil on the tree screen: no name.
    var sessionName: String?
    /// The "waiting on you" cue next to the name, set when a gate-hold banner opened this terminal (D-02).
    var showsWaitingCue = false
    let onBack: () -> Void
    /// The Terminal button, shown on the tree screen only. Off by default.
    var showsTerminal = false
    var onTerminal: () -> Void = {}
    /// The Workflow button, shown on the tree screen only. Off by default.
    var showsWorkflow = false
    var onWorkflow: () -> Void = {}
    let onClose: () -> Void
    @Environment(\.kitAccent) private var accent

    /// The count wording at the right edge of the band, waiting first. A count of 0 is left out.
    static func countParts(waiting: Int, running: Int) -> [(status: WorkerStatus, text: String)] {
        var parts: [(status: WorkerStatus, text: String)] = []
        if waiting > 0 { parts.append((.waiting, "\(waiting) waiting")) }
        if running > 0 { parts.append((.running, "\(running) running")) }
        return parts
    }

    var body: some View {
        KitHeaderBar {
            Text("❯").kitType(.body).foregroundStyle(accent.text).accessibilityHidden(true)
            if showsBack {
                Button(action: onBack) { KitLabel("Back", icon: .back) }
                    .buttonStyle(.kit)
                    .accessibilityLabel("Back")
            }
            if showsActions {
                Button(action: onClose) { KitLabel("Close", icon: .close) }
                    .buttonStyle(.kit)
                    .accessibilityLabel("Close project")
            }
            if showsWorkflow {
                Button(action: onWorkflow) { Text("Workflow") }
                    .buttonStyle(.kit)
                    .accessibilityLabel("Open workflow")
            }
            if showsTerminal {
                Button(action: onTerminal) { Text("Terminal") }
                    .buttonStyle(.kit)
                    .accessibilityLabel("Open terminal")
            }
            if let sessionName {
                Text(sessionName).kitType(.label).foregroundStyle(Ink.text).lineLimit(1)
            }
            if showsWaitingCue {
                Text(WorkerStatus.waiting.rawValue).kitType(.meta).foregroundStyle(Ink.waiting)
            }
            Spacer()
            ForEach(Array(Self.countParts(waiting: waiting, running: running).enumerated()), id: \.offset) { _, part in
                Text(part.text).kitType(.label).foregroundStyle(part.status.ink)
            }
        }
        .background(ZoomOnDoubleClick())
    }
}

/// The bottom bar of a project, under the tree or a terminal (D-13a point 2). Text in the field goes to the orchestrator pane as a
/// new task request through the delivery the Dispatch sheet uses, and the field clears on a send. An empty field opens the sheet.
/// A refused or failed send, or a text over the limit, keeps the text and shows the reason above the bar. The model fixes its pane
/// at creation, so the caller keys this view to the session.
struct DispatchPromptBar: View {
    let onOpenSheet: () -> Void
    let onSent: () -> Void
    @State private var text = ""
    @StateObject private var model: DispatchModel

    init(base: String, onOpenSheet: @escaping () -> Void, onSent: @escaping () -> Void) {
        self.onOpenSheet = onOpenSheet
        self.onSent = onSent
        _model = StateObject(wrappedValue: DispatchModel(deliver: { InboxDelivery.deliver($0, base: base) }))
    }

    var body: some View {
        VStack(spacing: Space.none) {
            if let message = model.message { KitFooterLine { Text(message) } }
            KitPromptBar(text: $text) { Task { await model.sendRequest(text, openSheet: onOpenSheet) } }
                .disabled(model.isSending)
        }
        .onChange(of: model.sent) { if model.sent { text = ""; onSent() } }
    }
}
