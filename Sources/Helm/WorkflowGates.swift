import Foundation

/// The next legal stage and the hard gates G1, G2 and G4 (D-05, D-06). Pure: no I/O. Gates cover the app's buttons only.
enum WorkflowGates {
    enum Stage: String, Equatable {
        case context, plan, execute, verify, milestone

        /// The order is context, plan, execute, verify, milestone.
        var following: Stage? {
            switch self {
            case .context: return .plan
            case .plan: return .execute
            case .execute: return .verify
            case .verify: return .milestone
            case .milestone: return nil
            }
        }
    }

    enum Verdict: Equatable {
        case allowed
        case blocked(String)
    }

    /// `stage` is nil when there is no next stage, and `reason` then says why. `phase` is the exact status text of
    /// the phase the stage is for. The app's derivation wins over `cursor.next`.
    struct Next: Equatable {
        var stage: Stage?
        var phase: String?
        var reason: String?
    }

    static func nextStage(status: CadenceStatus, hasContext: Bool, skipDiscuss: Bool) -> Next {
        let counts = Dictionary(status.phases.map { ($0.n, 1) }, uniquingKeysWith: +)
        if let dup = counts.first(where: { $0.value > 1 })?.key {
            return Next(stage: nil, phase: nil, reason: "Two phases share the number \(dup), so the next stage is not clear.")
        }
        guard let open = status.phases.first(where: { $0.status != "complete" }) else {
            guard let last = status.phases.last else {
                return Next(stage: nil, phase: nil, reason: "The status lists no phases.")
            }
            if status.cycle == "none" {
                return Next(stage: nil, phase: nil, reason: "The milestone is closed, so there is no next stage.")
            }
            return Next(stage: .milestone, phase: last.n, reason: nil)
        }
        switch open.status {
        case "unplanned": return Next(stage: hasContext || skipDiscuss ? .plan : .context, phase: open.n, reason: nil)
        case "planned": return Next(stage: .execute, phase: open.n, reason: nil)
        case "executed": return Next(stage: .verify, phase: open.n, reason: nil)
        default: return Next(stage: nil, phase: open.n, reason: "Phase \(open.n) has the status \"\(open.status)\", which this app does not know.")
        }
    }

    /// The gate verdict for any stage, judged against the first phase that is not complete.
    static func verdict(for stage: Stage, status: CadenceStatus, hasContext: Bool, skipDiscuss: Bool,
                        audit: Result<Int, CadenceLocator.Failure>?) -> Verdict {
        switch stage {
        case .plan where !hasContext && !skipDiscuss:
            return .blocked("G1: this phase has no CONTEXT.md and skip discuss is off. Run context first.")
        case .execute where status.phases.first(where: { $0.status != "complete" })?.status == "unplanned":
            return .blocked("G2: this phase is unplanned. Plan it before you execute it.")
        case .milestone:
            switch audit {
            case .success(let broken) where broken > 0:
                return .blocked("G4: the audit finds \(broken) problems in this milestone: broken requirements, coverage breaks or version drift.")
            case .failure(let problem):
                return .blocked("G4: the audit did not run. \(problem.reason)")
            case nil:
                return .blocked("G4: the audit has not run.")
            default: return .allowed
            }
        default: return .allowed
        }
    }
}
