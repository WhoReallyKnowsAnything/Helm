import Foundation

/// The Approve and Change notes button rules of the plan review screen (D-01..D-05, D-08). Pure: no merge call,
/// no send. The caller owns both.
enum PlanReviewActions {
    static let gateKey = "review.triggers.plan.gate"
    static let inFlightWarning =
        "A review is still running. If you approve now, its findings may be left behind in the worktree."

    struct Button: Equatable {
        var enabled: Bool
        /// Shown beside the button when it is off.
        var reason: String?
        /// Approve only: ask first, because a review is in flight.
        var needsConfirmation = false

        static func off(_ reason: String) -> Button { Button(enabled: false, reason: reason) }
    }

    /// `nil` buttons: the planned state shows none (D-08).
    struct Result: Equatable {
        var approve: Button?
        var notes: Button?
    }

    enum Decision: Equatable {
        case start
        case ask
        case refuse(String)
    }

    /// `gate` is the current text of `review.triggers.plan.gate`, nil when the config check could not read it.
    /// `notesInFlight` is the sender's flag; plan 1's state rule already folds it into `reviewInFlight`.
    static func make(state: PlanReviewState, gate: String?, notesInFlight: Bool) -> Result {
        let approve: Button
        var notes = Button(enabled: false)
        switch state {
        case .planned:
            return Result(approve: nil, notes: nil)
        case .readyForReview(let inFlight):
            approve = Button(enabled: true, needsConfirmation: inFlight)
            notes = Button(enabled: true)
        case .readyWorkerEnded(let inFlight):
            approve = Button(enabled: true, needsConfirmation: inFlight)
            notes = .off("worker ended")
        case .didNotFinish:
            approve = .off("worker did not finish")
            notes = .off("worker did not finish")
        case .planRunning:
            approve = .off("plan is still running")
            notes = .off("plan is still running")
        case .finishedNoPlanFiles:
            approve = .off("no plan files in the worktree")
            notes = .off("no plan files in the worktree")
        case .noPlan:
            approve = .off("no plan to approve")
            notes = .off("no plan to change")
        }
        // Gate first, then the in-flight flag, then the state rule (D-03).
        if gate == "off" {
            notes = .off("\(gateKey) is off")
        } else if notesInFlight {
            notes = .off("notes being applied")
        }
        return Result(approve: approve, notes: notes)
    }

    static func decide(_ approve: Button, confirmed: Bool) -> Decision {
        guard approve.enabled else { return .refuse(approve.reason ?? "Approve is off") }
        return approve.needsConfirmation && !confirmed ? .ask : .start
    }

    /// One Change notes press. `send` runs only when the button is on.
    static func pressNotes(_ notes: Button?, send: () -> Void) {
        if notes?.enabled == true { send() }
    }

    /// One Approve press. Calls `start` with the label only when `decide` says start; the caller shows the confirmation on `.ask`.
    @discardableResult
    static func press(_ approve: Button, confirmed: Bool, label: String, start: (String) -> Void) -> Decision {
        let decision = decide(approve, confirmed: confirmed)
        if decision == .start { start(label) }
        return decision
    }
}
