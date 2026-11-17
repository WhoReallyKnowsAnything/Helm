import Foundation

/// The one state the plan review screen is in (D-05). Pure: the overlay, liveness and file facts come in.
/// Plan 2 builds the button rules on this value and adds nothing to it.
enum PlanReviewState: Equatable {
    case planRunning
    /// `reviewInFlight`: the review file is absent, or a Notes round is in flight.
    case readyForReview(reviewInFlight: Bool)
    /// The done mark exists but the process is gone.
    case readyWorkerEnded(reviewInFlight: Bool)
    case finishedNoPlanFiles
    /// Dead overlay: no done mark.
    case didNotFinish
    /// Read-only from the project folder, no buttons.
    case planned
    case noPlan

    /// `overlay` is the phase 1 state of the `cad-plan-p<N>` label. A starting worker is a running overlay, so it is `planRunning`.
    static func make(
        overlay: WorkflowOverlay.State?, alive: Bool, planned: Bool, hasPlanFiles: Bool, reviewExists: Bool, notesInFlight: Bool
    ) -> PlanReviewState {
        let inFlight = !reviewExists || notesInFlight
        switch overlay {
        case .running?: return .planRunning
        case .dead?: return .didNotFinish
        case .waitingForMerge?:
            guard hasPlanFiles else { return .finishedNoPlanFiles }
            return alive ? .readyForReview(reviewInFlight: inFlight) : .readyWorkerEnded(reviewInFlight: inFlight)
        case nil: return planned ? .planned : .noPlan
        }
    }

    var text: String {
        switch self {
        case .planRunning: return "Plan running"
        case .readyForReview: return "Plan ready for review"
        case .readyWorkerEnded: return "Plan ready for review, worker ended"
        case .finishedNoPlanFiles: return "No plan files in the worktree"
        case .didNotFinish: return "worker did not finish"
        case .planned: return "Planned"
        case .noPlan: return "No plan"
        }
    }
}
