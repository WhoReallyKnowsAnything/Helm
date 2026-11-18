import Foundation

/// G3 (D-06, D-07, D-08): the 3 merge routes of a `cad-verify-p<N>` worker stay off until `uat status` is complete and
/// UAT.md is committed in the worker's worktree. Pure: no I/O. Every other label is not gated.
enum UATGate {
    enum Committed: Equatable {
        case committed, notCommitted
        case error(String)
    }

    enum Verdict: Equatable {
        case notGated
        case checking
        case blocked(String)
        case confirmSkipped(Int)
        case allowed
    }

    enum Press: Equatable {
        case proceed
        case confirm(Int)
        case stop(String)
    }

    /// The phase text of an exact `cad-verify-p<N>` or `cad-verify-p<N>-<M>` label (`p1-1` gives "1.1"), else nil.
    /// The label function must give the same label back, so no other spelling matches.
    static func phase(ofLabel label: String) -> String? {
        guard label.range(of: #"^cad-verify-p[0-9]+(-[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        let text = label.dropFirst("cad-verify-p".count).replacingOccurrences(of: "-", with: ".")
        return WorkflowDispatch.label(stage: .verify, phase: text) == label ? text : nil
    }

    /// Fails closed: only a complete result that is committed gives `allowed` or `confirmSkipped`.
    static func verdict(match: String?, status: UATStatus.Outcome, committed: Committed) -> Verdict {
        guard match != nil else { return .notGated }
        switch status {
        case .notStarted: return .blocked("UAT not started: no UAT.md")
        case .unreadable(let reason): return .blocked("UAT could not be read: \(reason)")
        case .loaded(let loaded):
            guard loaded.result == "complete" else { return .blocked(partialReason(loaded.counts)) }
            switch committed {
            case .error(let text): return .blocked(text)
            case .notCommitted: return .blocked("UAT.md is not committed in the worktree")
            case .committed: return loaded.counts.skipped > 0 ? .confirmSkipped(loaded.counts.skipped) : .allowed
            }
        }
    }

    private static func partialReason(_ counts: UATStatus.Counts) -> String {
        let parts = [("fail", counts.fail), ("blocked", counts.blocked), ("pending", counts.pending)]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        if !parts.isEmpty { return "UAT is not complete: " + parts.joined(separator: ", ") }
        return counts == UATStatus.Counts() ? "UAT has no items" : "UAT is not complete"
    }

    static func press(_ verdict: Verdict) -> Press {
        switch verdict {
        case .notGated, .allowed: return .proceed
        case .confirmSkipped(let count): return .confirm(count)
        case .blocked(let reason): return .stop(reason)
        case .checking: return .stop("checking UAT")
        }
    }
}
