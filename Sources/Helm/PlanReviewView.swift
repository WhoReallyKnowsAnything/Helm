import SwiftUI

/// The plan review screen of one phase. Read-only: it has no send path of its own. Answerable cards go through
/// `RequestCards`, the only caller of the store's `answer`. Keyed by the phase text, so a merge that moves the stage leaves it open.
struct PlanReviewView: View {
    let phase: String
    let project: String?
    let worktree: String?
    let overlay: WorkflowOverlay?
    let planned: Bool
    @ObservedObject var requests: RequestStore
    var onClear: (String) -> Void = { _ in }
    /// Current text of `review.triggers.plan.gate`, nil when the config check could not read it.
    var gate: String? = nil
    /// Starts the existing merge-review flow for the label. The merge sheet's own Confirm is the approval (D-01).
    var onApprove: (String) -> Void = { _ in }

    /// The loaded worker rows, for the Notes send and its in-flight flag.
    var rows: [WorkerRow] = []
    /// `WorkflowStore.endedLabels`: labels whose window tmux reports gone.
    var endedLabels: Set<String> = []

    @StateObject private var store = PlanReviewStore()
    @StateObject private var sender = PlanNoteSender()
    @State private var confirmingApprove = false

    private var buttons: PlanReviewActions.Result {
        PlanReviewActions.make(state: screenState, gate: gate, notesInFlight: sender.notesInFlight)
    }

    private var workerGone: Bool {
        if case .running? = planOverlay { return false }
        if case .waitingForMerge? = planOverlay { return false }
        return true
    }

    private var label: String { WorkflowDispatch.label(stage: .plan, phase: phase) }
    private var planOverlay: WorkflowOverlay.State? { overlay?.stage == .plan ? overlay?.state : nil }
    private var entries: [RequestStore.Entry] { requests.entries(for: label).filter { $0.project.isEmpty } }

    private var cardState: ContextCardState.State {
        ContextCardState.state(label: label, overlay: planOverlay, live: true)
    }

    private var screenState: PlanReviewState {
        .make(overlay: planOverlay, alive: !endedLabels.contains(label), planned: planned, hasPlanFiles: store.data.hasPlanFiles,
              reviewExists: store.data.reviewExists, notesInFlight: sender.notesInFlight)
    }

    var body: some View {
        let text = PlanReviewText.make(
            phase: phase, data: store.data, state: screenState, cardState: cardState, entries: entries,
            answered: requests.answered(for: label))
        VStack(alignment: .leading, spacing: Space.none) {
        actionRow
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(text.header).kitType(.meta).foregroundStyle(Ink.textSecondary)
                if let note = text.note { Text(note).kitType(.meta).foregroundStyle(Ink.waiting) }
                if let line = text.reviewLine { reviewView(line, isPath: text.reviewIsPath) }
                if let empty = text.emptyLine { Text(empty).kitType(.meta).foregroundStyle(Ink.textSecondary) }
                HStack(alignment: .top, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(text.waves, id: \.title) { wave in
                            Text(wave.title).kitType(.section).foregroundStyle(Ink.text)
                            ForEach(wave.plans, id: \.name) { planView($0) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    if !text.criteria.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Acceptance criteria").kitType(.section).foregroundStyle(Ink.text)
                            ForEach(Array(text.criteria.enumerated()), id: \.offset) { _, c in
                                Text(c).kitType(.meta).foregroundStyle(Ink.text).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                if let notes = buttons.notes { notesBox(notes) }
                cards(text)
                ForEach(Array(text.answered.enumerated()), id: \.offset) { _, line in
                    Text(line).kitType(.meta).foregroundStyle(Ink.textSecondary)
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
        .onChange(of: rows) { sender.observe(rows: rows, phase: phase, workerGone: workerGone) }
        .onChange(of: planOverlay) { sender.observe(rows: rows, phase: phase, workerGone: workerGone) }
    }

    private func notesBox(_ notes: PlanReviewActions.Button) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            TextEditor(text: $sender.notes)
                .frame(minHeight: Metric.promptFieldMaxHeight / 2, maxHeight: Metric.promptFieldMaxHeight)
                .disabled(!notes.enabled)
            HStack(spacing: Space.sm) {
                if let reason = notes.reason { Text(reason).kitType(.meta).foregroundStyle(Ink.textSecondary) }
                if let outcome = sender.outcome { Text(Self.outcomeText(outcome)).kitType(.meta).foregroundStyle(Ink.textSecondary) }
            }
        }
    }

    private static func outcomeText(_ outcome: InboxDelivery.Outcome) -> String {
        switch outcome {
        case .sent: return "Notes sent"
        case .refused(let reason), .failed(let reason): return reason
        }
    }

    /// The worktree only while it exists.
    private var worktreeURL: URL? {
        guard let worktree, FileManager.default.fileExists(atPath: worktree) else { return nil }
        return URL(fileURLWithPath: worktree)
    }

    private var actionRow: some View {
        let approve = buttons.approve
        return KitStageActionRow(primaryTitle: "Approve",
                          primaryReason: approve.map { $0.enabled ? nil : ($0.reason ?? "Approve is off") } ?? "no plan to approve yet",
                          onPrimary: {
                              guard let approve else { return }
                              if PlanReviewActions.press(approve, confirmed: false, label: label, start: onApprove) == .ask {
                                  confirmingApprove = true
                              }
                          }, secondary: {
                              if let notes = buttons.notes {
                                  Button("Change Notes") {
                                      PlanReviewActions.pressNotes(notes) { Task { await sender.send(phase: phase, rows: rows) } }
                                  }
                                  .buttonStyle(.kit)
                                  .disabled(!notes.enabled || sender.sending)
                              }
                              if screenState == .didNotFinish {
                                  Button { onClear(label) } label: { Text("Clear \(label)") }.buttonStyle(.kit)
                              }
                          }, menu: { EmptyView() })
        .confirmationDialog("Approve while a review is running?", isPresented: $confirmingApprove) {
            Button("Approve Anyway") {
                if let approve { PlanReviewActions.press(approve, confirmed: true, label: label, start: onApprove) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PlanReviewActions.inFlightWarning)
        }
    }

    private func point() { store.point(project: project, phase: phase, worktree: worktree) }

    @ViewBuilder private func link(_ text: String) -> some View {
        if let project {
            FileLinkView(text: text, project: URL(fileURLWithPath: project), worktree: worktreeURL,
                         canLink: PlanReviewText.canLink)
                .kitType(.meta).foregroundStyle(Ink.text)
        } else {
            Text(text).kitType(.meta).foregroundStyle(Ink.text)
        }
    }

    @ViewBuilder private func reviewView(_ line: String, isPath: Bool) -> some View {
        if isPath { link(line) } else { Text(line).kitType(.meta).foregroundStyle(Ink.waiting) }
    }

    private func planView(_ plan: PlanReviewText.PlanText) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(plan.heading).kitType(.section).foregroundStyle(Ink.text)
            if !plan.requirements.isEmpty {
                Text("Requirements: " + plan.requirements.joined(separator: ", ")).kitType(.meta).foregroundStyle(Ink.textSecondary)
            }
            if !plan.dependsOn.isEmpty {
                Text("Depends on: " + plan.dependsOn.joined(separator: ", ")).kitType(.meta).foregroundStyle(Ink.textSecondary)
            }
            if !plan.mustBeTrue.isEmpty {
                Text("Must be true when done").kitType(.meta).foregroundStyle(Ink.textSecondary)
                ForEach(Array(plan.mustBeTrue.enumerated()), id: \.offset) { _, b in
                    Text("- " + b).kitType(.meta).foregroundStyle(Ink.text).textSelection(.enabled)
                }
            }
            ForEach(Array(plan.tasks.enumerated()), id: \.offset) { _, task in
                VStack(alignment: .leading, spacing: Metric.toolLineGap) {
                    Text(task.name).kitType(.meta).foregroundStyle(Ink.text)
                    ForEach(task.files, id: \.self) { link($0) }
                    Text("Action: " + task.action).kitType(.meta).foregroundStyle(Ink.text).textSelection(.enabled)
                    Text("Verify: " + task.verify).kitType(.meta).foregroundStyle(Ink.text).textSelection(.enabled)
                }
            }
            if let raw = plan.raw { Text(raw).kitType(.meta).foregroundStyle(Ink.text).textSelection(.enabled) }
        }
    }

    @ViewBuilder private func cards(_ text: PlanReviewText) -> some View {
        switch text.cardState {
        case .noCard:
            EmptyView()
        case .answerable:
            RequestCards(entries: entries, card: requests.card(for:), onAnswer: requests.answer,
                         question: QuestionBinding(requests), stamp: requests.stamp)
        case .workerEnded, .waitingForMerge, .starting:
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(text.heldCards.enumerated()), id: \.offset) { _, card in
                    KitHoldCard(stateLine: card.stateLine, outcome: card.outcome) {
                        HoldCommandText(text: card.command)
                    } decision: {
                        if text.offersClear {
                            Button { onClear(label) } label: { Text("Clear \(label)") }.buttonStyle(.kit)
                        }
                    }
                }
            }
        }
    }
}
