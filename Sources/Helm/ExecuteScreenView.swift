import SwiftUI

/// The execute progress screen of one phase: waves, each plan's state, task rows and the report's own words for a
/// failure or checkpoint. Read-only. Keyed by the phase text, so a merge that moves the stage leaves it open.
struct ExecuteScreenView: View {
    let phase: String
    let project: String?
    let worktree: String?
    let overlay: WorkflowOverlay?
    /// The worker's window is live (running overlay, label not in `WorkflowStore.endedLabels`).
    let live: Bool
    @ObservedObject var requests: RequestStore
    let onClear: (String) -> Void
    /// The board's panel and press: Next acts on the cursor's target, so it is on only when that target is verify of this phase.
    var panel: WorkflowPanel?
    var onPress: () -> Void = {}

    @StateObject private var store = ExecuteScreenStore()

    /// Why "Next: verify" is off, nil when it works.
    static func primaryOff(panel: WorkflowPanel?, phase: String, live: Bool) -> String? {
        if live { return "a plan is still running" }
        if let reason = panel.nextReason(phase: phase) { return reason }
        if let stage = panel?.next?.stage, stage != .verify { return "The next stage is \(stage.rawValue), not verify." }
        return nil
    }

    private var label: String { WorkflowDispatch.label(stage: .execute, phase: phase) }
    private var cardState: ContextCardState.State { ContextCardState.state(label: label, overlay: overlay?.state, live: live) }
    private var entries: [RequestStore.Entry] { requests.entries(for: label).filter { $0.project.isEmpty } }

    @ViewBuilder private var cards: some View {
        switch cardState {
        case .noCard:
            EmptyView()
        case .answerable:
            RequestCards(entries: entries, card: requests.card(for:), onAnswer: requests.answer,
                         question: QuestionBinding(requests).withTypedAnswers(requests), stamp: requests.stamp)
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

    /// A line that can hold a file path: a link when a project is open (D-06), else plain text.
    @ViewBuilder private func linked(_ line: String) -> some View {
        if let project {
            FileLinkView(text: line, project: URL(fileURLWithPath: project), worktree: worktree.map { URL(fileURLWithPath: $0) })
        } else {
            Text(line)
        }
    }

    var body: some View {
        let text = ExecuteScreenText.make(phase: phase, data: store.data, overlay: overlay, live: live,
                                         questionOpen: entries.contains { $0.live && $0.request.toolName == "AskUserQuestion" })
        VStack(alignment: .leading, spacing: Space.none) {
        KitStageActionRow(primaryTitle: "Next: Verify", primaryReason: Self.primaryOff(panel: panel, phase: phase, live: live),
                          onPrimary: onPress, secondary: { EmptyView() }, menu: { EmptyView() })
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(text.header).kitType(.meta).foregroundStyle(Ink.textSecondary)
                cards
                if let copy = text.copyLine { Text(copy).kitType(.meta).foregroundStyle(Ink.textSecondary) }
                if let message = text.message { Text(message).kitType(.meta).foregroundStyle(Ink.waiting) }
                ForEach(Array(text.waves.enumerated()), id: \.offset) { _, wave in
                    Text(wave.title).kitType(.section).foregroundStyle(Ink.text)
                    ForEach(wave.plans, id: \.title) { plan in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(plan.title).kitType(.section).foregroundStyle(plan.failure ? Ink.waiting : Ink.text)
                            if let git = plan.gitLine { linked(git).kitType(.meta).foregroundStyle(Ink.waiting) }
                            ForEach(Array(plan.rows.enumerated()), id: \.offset) { _, row in
                                linked("\(row.task)  \(row.commit)  \(row.note)").kitType(.meta).foregroundStyle(Ink.textSecondary)
                            }
                            if let headline = plan.headline { linked(headline).kitType(.meta).foregroundStyle(Ink.waiting) }
                            if let body = plan.body, !body.isEmpty { linked(body).kitType(.meta).foregroundStyle(Ink.text) }
                            if let answer = plan.answerLine { linked(answer).kitType(.meta).foregroundStyle(Ink.waiting) }
                        }
                    }
                }
            }
            .padding(Space.sm)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: point)
        .onChange(of: project) { point() }
        .onChange(of: worktree) { point() }
        .onChange(of: phase) { point() }
        }
    }

    private func point() { store.point(project: project, phase: phase, worktree: worktree) }
}
