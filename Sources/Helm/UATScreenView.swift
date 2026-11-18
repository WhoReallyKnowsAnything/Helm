import SwiftUI

/// The UAT screen of one phase. Only the current item has result buttons; they append a fixed line to the verify
/// worker's inbox through the store. Keyed by the phase text, so a merge that moves the stage leaves it open.
struct UATScreenView: View {
    let phase: String
    let project: String?
    let worktree: String?
    let overlay: WorkflowOverlay?
    /// The verify worker's inbox path, nil when its row has none.
    var inbox: String?
    /// The worker's window is live (not in `WorkflowStore.endedLabels`).
    var live = false
    @ObservedObject var requests: RequestStore
    var onClear: (String) -> Void = { _ in }

    @StateObject private var store = UATScreenStore()
    @State private var open: UATResult.Kind?
    @State private var noteText = ""

    private var label: String { WorkflowDispatch.label(stage: .verify, phase: phase) }
    private var cardState: ContextCardState.State { UATScreenText.cardState(phase: phase, overlay: overlay, live: live) }
    private var entries: [RequestStore.Entry] { requests.entries(for: label).filter { $0.project.isEmpty } }

    private var firstPending: Int? {
        if case .loaded(let s) = store.data.status { return s.firstPending?.k }
        return nil
    }

    var body: some View {
        let text = UATScreenText.make(phase: phase, data: store.data, overlay: overlay, live: live, inbox: inbox,
                                      readback: store.readback)
        VStack(alignment: .leading, spacing: Space.none) {
        actionRow(text)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(text.header).kitType(.meta).foregroundStyle(Ink.textSecondary)
                cards
                ForEach(Array(requests.answered(for: label).flatMap { a in
                    a.questions.map { "\($0.display): \(a.picks[$0.text]?.joined(separator: ", ") ?? "")" }
                }.enumerated()), id: \.offset) { _, line in
                    Text(line).kitType(.meta).foregroundStyle(Ink.textSecondary)
                }
                if let copy = text.copyLine { Text(copy).kitType(.meta).foregroundStyle(Ink.textSecondary) }
                if let counts = text.countsLine { Text(counts).kitType(.meta).foregroundStyle(Ink.text) }
                if let message = text.message { Text(message).kitType(.meta).foregroundStyle(Ink.waiting) }
                if let link = text.rawFileLink { linked(link) }
                ForEach(text.rows, id: \.number) { row in
                    VStack(alignment: .leading, spacing: Metric.toolLineGap) {
                        Text("\(row.number). \(row.name)  [\(row.status)]\(row.source.map { "  \($0)" } ?? "")")
                            .kitType(.section).foregroundStyle(Ink.text)
                        linked(row.expected)
                        if let note = row.note { linked(note) }
                        if let readback = row.readback { Text(readback).kitType(.meta).foregroundStyle(Ink.textSecondary) }
                        if row.isCurrent { controls(row.number, off: text.controlsOff) }
                    }
                }
            }
            .padding(Space.sm)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: point)
        .onChange(of: project) { point() }
        .onChange(of: worktree) { point() }
        .onChange(of: phase) { point() }
    }

    /// Pass is the one primary; Fail, Skip and Blocked open the note field below the current item.
    private func actionRow(_ text: UATScreenText) -> some View {
        let current = text.rows.first(where: \.isCurrent)?.number
        return KitStageActionRow(primaryTitle: "Pass", primaryReason: current == nil ? "no current item" : text.controlsOff,
                          onPrimary: { if let current { send(current, .pass) } },
                          secondary: {
                              ForEach([UATResult.Kind.fail, .skip, .blocked], id: \.self) { kind in
                                  Button(kind.rawValue.capitalized) { open = kind; noteText = "" }.buttonStyle(.kit)
                                      .disabled(current == nil || text.controlsOff != nil)
                              }
                          }, menu: { EmptyView() })
    }

    @ViewBuilder private func controls(_ item: Int, off: String?) -> some View {
        if off == nil, let kind = open {
            HStack {
                TextField("", text: $noteText, prompt: Text(kind == .fail ? "what went wrong" : "reason"))
                Button("Send") { send(item, kind) }.buttonStyle(.kit).disabled(!UATResult.canSend(noteText))
            }
        }
        if case .refused(let why)? = store.outcome { Text(why).kitType(.meta).foregroundStyle(Ink.waiting) }
        if case .failed(let why)? = store.outcome { Text(why).kitType(.meta).foregroundStyle(Ink.waiting) }
    }

    private func send(_ item: Int, _ kind: UATResult.Kind) {
        let note = noteText
        store.send(item: String(item), kind: kind, text: kind.needsText ? note : nil, firstPending: firstPending,
                   state: overlay?.state, live: live, inbox: inbox)
        // A refusal keeps the field open with its message; anything else clears the text.
        if case .refused? = store.outcome { return }
        open = nil
        noteText = ""
    }

    @ViewBuilder private var cards: some View {
        switch cardState {
        case .noCard:
            EmptyView()
        case .answerable:
            RequestCards(entries: entries, card: requests.card(for:), onAnswer: requests.answer,
                         question: QuestionBinding(requests), stamp: requests.stamp)
        case .workerEnded, .waitingForMerge, .starting:
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(entries) { entry in
                    if let card = ContextCardState.card(for: entry, state: cardState) {
                        KitHoldCard(stateLine: card.stateLine, outcome: card.outcome) {
                            HoldCommandText(text: card.command)
                        } decision: {
                            if ContextCardState.offersClear(cardState) {
                                Button { onClear(label) } label: { Text("Clear \(label)") }.buttonStyle(.kit)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Paths in the text are links; a click opens the worktree copy while it exists, else the project copy.
    @ViewBuilder private func linked(_ text: String) -> some View {
        if let project {
            FileLinkView(text: text, project: URL(fileURLWithPath: project), worktree: worktreeURL)
                .kitType(.meta).foregroundStyle(Ink.text)
        } else {
            Text(text).kitType(.meta).foregroundStyle(Ink.text)
        }
    }

    private var worktreeURL: URL? {
        guard let worktree, FileManager.default.fileExists(atPath: worktree) else { return nil }
        return URL(fileURLWithPath: worktree)
    }

    private func point() { store.point(project: project, phase: phase, worktree: worktree) }
}
