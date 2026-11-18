import Foundation

/// Which dispatch stages have a worker whose questions an app screen answers. Keyed by the DISPATCH stage that
/// the `cad-<stage>-p<N>` label carries, not by the board's display stage. Phase 4 adds `plan`, phase 5 `verify`,
/// the execute screen adds `execute` (D-04).
enum ContextCardState {
    static let screenStages: Set<WorkflowGates.Stage> = [.context, .plan, .execute, .verify, .milestone]

    /// The dispatch stage a worker label carries, or nil for any other label (`cad-config`, `dashboard`).
    static func dispatchStage(ofLabel label: String) -> WorkflowGates.Stage? {
        guard label.range(of: #"^cad-[a-z]+-p[0-9]+(-[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        let name = label.dropFirst(4).prefix { $0 != "-" }
        return WorkflowGates.Stage(rawValue: String(name))
    }

    /// True when the label's dispatch stage is in the table.
    static func hasScreen(label: String) -> Bool {
        dispatchStage(ofLabel: label).map(screenStages.contains) ?? false
    }

    /// Open is offered for a phase in the context stage, or with a held context worker (D-06).
    static func offersOpen(display: WorkflowStageMap.Display, contextState: WorkflowOverlay.State?) -> Bool {
        display == .stage(.context) || contextState != nil
    }

    /// UAT Open is offered for a phase in the verify stage, or with a held verify worker, in every worker state.
    static func offersOpenUAT(display: WorkflowStageMap.Display, verifyState: WorkflowOverlay.State?) -> Bool {
        display == .stage(.verify) || verifyState != nil
    }

    /// Execute Open is offered for a phase that has plans, or with a held execute worker in any state (UD-1).
    static func offersOpenExecute(hasPlans: Bool, executeState: WorkflowOverlay.State?) -> Bool {
        hasPlans || executeState != nil
    }

    enum State: Equatable {
        case answerable
        /// Dead overlay only (D-03): Clear is offered, no answer controls.
        case workerEnded
        case waitingForMerge
        /// Running overlay but no live process yet: no controls, no Clear, no "worker ended".
        case starting
        case noCard
    }

    /// What the screen does with a pending request of `label`. The overlay decides; the row's own status never does.
    static func state(label: String, overlay: WorkflowOverlay.State?, live: Bool) -> State {
        guard hasScreen(label: label), let overlay else { return .noCard }
        switch overlay {
        case .running: return live ? .answerable : .starting
        case .dead: return .workerEnded
        case .waitingForMerge: return .waitingForMerge
        }
    }

    /// The card for every state except answerable (that one is `RequestStore.card(for:)`). Never has buttons.
    static func card(for entry: RequestStore.Entry, state: State) -> RequestStore.Card? {
        let line: String
        switch state {
        case .workerEnded: line = "worker ended"
        case .waitingForMerge: line = "waiting for merge"
        case .starting: line = "starting"
        case .answerable, .noCard: return nil
        }
        return RequestStore.Card(command: shownText(entry), stateLine: line, outcome: nil, showsButtons: false, enabled: false)
    }

    /// The question header and text of an AskUserQuestion request, else the request's own text. Never the raw tool input.
    private static func shownText(_ entry: RequestStore.Entry) -> String {
        let questions = entry.request.toolName == "AskUserQuestion" ? QuestionInput.decode(entry.request.input) : []
        guard !questions.isEmpty else { return entry.request.text }
        return questions.map { [$0.headerDisplay, $0.display].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// Clear is offered for a dead worker's card only.
    static func offersClear(_ state: State) -> Bool { state == .workerEnded }
}
