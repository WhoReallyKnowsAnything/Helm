import SwiftUI

/// The context screen of one phase. Keyed by the phase text, so a merge that moves the stage leaves it open.
/// It has no send path of its own: answerable cards go through `RequestCards`, the only caller of the store's `answer`.
struct ContextScreenView: View {
    let phase: String
    let project: String?
    let worktree: String?
    let overlay: WorkflowOverlay?
    @ObservedObject var requests: RequestStore
    var onClear: (String) -> Void = { _ in }
    /// The board's panel and press: Next acts on the cursor's target, so it is off for any other phase.
    var panel: WorkflowPanel?
    var onPress: () -> Void = {}

    @StateObject private var store = ContextScreenStore()

    private var label: String { WorkflowDispatch.label(stage: .context, phase: phase) }

    /// Same inputs as the board's question-waiting rule, so overlay none shows no card.
    private var state: ContextCardState.State {
        ContextCardState.state(label: label, overlay: overlay?.state, live: true)
    }

    var body: some View {
        let text = ContextScreenText.make(
            phase: phase, data: store.data, overlay: overlay, state: state, answered: requests.answered(for: label))
        VStack(alignment: .leading, spacing: Space.none) {
        KitStageActionRow(primaryTitle: "Next: Plan", primaryReason: panel.nextReason(phase: phase), onPrimary: onPress,
                          secondary: {
                              if ContextCardState.offersClear(state) {
                                  Button { onClear(label) } label: { Text("Clear \(label)") }.buttonStyle(.kit)
                              }
                          }, menu: { EmptyView() })
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(text.header).kitType(.meta).foregroundStyle(Ink.textSecondary)
                cards
                ForEach(Array(text.answered.enumerated()), id: \.offset) { _, line in
                    Text(line).kitType(.meta).foregroundStyle(Ink.textSecondary)
                }
                ForEach(text.sections, id: \.heading) { section in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(section.heading).kitType(.section).foregroundStyle(Ink.text)
                        if let note = section.note { Text(note).kitType(.meta).foregroundStyle(Ink.waiting) }
                        ForEach(section.lines, id: \.title) { line in
                            VStack(alignment: .leading, spacing: Metric.toolLineGap) {
                                Text(line.title).kitType(.meta).foregroundStyle(Ink.textSecondary)
                                if let project {
                                    FileLinkView(text: line.text, project: URL(fileURLWithPath: project), worktree: worktreeURL)
                                        .kitType(.meta).foregroundStyle(Ink.text)
                                } else {
                                    Text(line.text).kitType(.meta).foregroundStyle(Ink.text)
                                }
                            }
                        }
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

    /// The worktree only while it exists.
    private var worktreeURL: URL? {
        guard let worktree, FileManager.default.fileExists(atPath: worktree) else { return nil }
        return URL(fileURLWithPath: worktree)
    }

    private func point() { store.point(project: project, phase: phase, worktree: worktree) }

    private var entries: [RequestStore.Entry] { requests.entries(for: label).filter { $0.project.isEmpty } }

    @ViewBuilder private var cards: some View {
        switch state {
        case .noCard:
            EmptyView()
        case .answerable:
            RequestCards(entries: entries, card: requests.card(for:), onAnswer: requests.answer,
                         question: QuestionBinding(requests), stamp: requests.stamp)
        case .workerEnded, .waitingForMerge, .starting:
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(entries) { entry in
                    if let card = ContextCardState.card(for: entry, state: state) {
                        KitHoldCard(stateLine: card.stateLine, outcome: card.outcome) {
                            HoldCommandText(text: card.command)
                        } decision: { EmptyView() }
                    }
                }
            }
        }
    }
}
