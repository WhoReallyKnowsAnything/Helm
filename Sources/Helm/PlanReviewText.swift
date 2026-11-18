import Foundation

/// The words the plan review screen draws, built from the store's values and the screen state. The view only draws this.
struct PlanReviewText {
    struct TaskText: Equatable {
        let name: String
        let files: [String]
        let action: String
        let verify: String
    }

    struct PlanText: Equatable {
        let name: String
        let heading: String
        let requirements: [String]
        let dependsOn: [String]
        let mustBeTrue: [String]
        let tasks: [TaskText]
        /// The file's own text, only when no task could be read from it.
        let raw: String?
    }

    struct Wave: Equatable {
        let title: String
        let plans: [PlanText]
    }

    let header: String
    /// "not merged yet" while the plan is read from the worktree.
    let note: String?
    let waves: [Wave]
    /// "No plan files yet" when there is nothing to list.
    let emptyLine: String?
    let criteria: [String]
    /// "review in flight", or the review file's relative path when `reviewIsPath`.
    let reviewLine: String?
    let reviewIsPath: Bool
    let answered: [String]
    let cardState: ContextCardState.State
    let answerableCount: Int
    /// Cards of every state except answerable. They never have answer controls.
    let heldCards: [RequestStore.Card]
    let offersClear: Bool

    /// A path links only when relative and without a `..` component (D-10).
    static func canLink(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.hasPrefix("~") && !path.split(separator: "/").contains("..")
    }

    static func make(
        phase: String, data: PlanReviewData, state: PlanReviewState, cardState: ContextCardState.State,
        entries: [RequestStore.Entry], answered: [AnsweredQuestions]
    ) -> PlanReviewText {
        let waves = data.waves.enumerated().map { index, plans in
            Wave(title: "Wave \(index + 1)", plans: plans.map(planText))
        }
        let inFlightState: Bool
        switch state {
        case .planRunning, .readyForReview, .readyWorkerEnded: inFlightState = true
        default: inFlightState = false
        }
        let reviewLine = data.reviewExists ? data.reviewPath : (inFlightState ? "review in flight" : nil)
        return PlanReviewText(
            header: "Plan review: phase \(phase) - \(state.text)",
            note: data.root == .worktree ? "not merged yet" : nil,
            waves: waves,
            emptyLine: waves.isEmpty ? "No plan files yet" : nil,
            criteria: data.criteria,
            reviewLine: reviewLine,
            reviewIsPath: data.reviewExists,
            answered: answered.flatMap { a in
                a.questions.map { "\($0.display): \(a.picks[$0.text]?.joined(separator: ", ") ?? "")" }
            },
            cardState: cardState,
            answerableCount: cardState == .answerable ? entries.count : 0,
            heldCards: entries.compactMap { ContextCardState.card(for: $0, state: cardState) },
            offersClear: ContextCardState.offersClear(cardState))
    }

    private static func planText(_ plan: PlanReviewPlan) -> PlanText {
        let p = plan.parsed
        let heading = p.heading.map { String($0.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) } ?? plan.name
        return PlanText(
            name: plan.name, heading: heading, requirements: p.requirements, dependsOn: p.dependsOn ?? [],
            mustBeTrue: p.mustBeTrue,
            tasks: p.tasks.map { TaskText(name: $0.name, files: $0.files, action: $0.action, verify: $0.verify) },
            raw: p.tasks.isEmpty ? p.raw : nil)
    }
}
