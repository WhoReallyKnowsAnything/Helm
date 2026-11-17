import Foundation
import Testing
@testable import OrchestratorGUI

struct UATGateTests {
    private func loaded(_ result: String, _ counts: UATStatus.Counts) -> UATStatus.Outcome {
        .loaded(UATStatus(status: "testing", counts: counts, result: result, firstPending: nil, ci: nil))
    }

    @Test func labelMatchIsExact() {
        #expect(UATGate.phase(ofLabel: "cad-verify-p3") == "3")
        #expect(UATGate.phase(ofLabel: "cad-verify-p1-1") == "1.1")
        for label in ["cad-execute-p3", "cad-plan-p3", "cad-context-p3", "cad-verify-p3x", "cad-verify-p3-",
                      "xcad-verify-p3", "cad-verifyx-p3", "fix-the-bug", "cad-verify-p", "cad-verify-p3-1-2"] {
            #expect(UATGate.phase(ofLabel: label) == nil, "\(label)")
        }
    }

    @Test func verdicts() {
        let m: String? = "3"
        #expect(UATGate.verdict(match: nil, status: .notStarted, committed: .committed) == .notGated)
        #expect(UATGate.verdict(match: m, status: loaded("complete", .init(pass: 6)), committed: .committed) == .allowed)
        #expect(UATGate.verdict(match: m, status: loaded("complete", .init(pass: 4, skipped: 2)), committed: .committed) == .confirmSkipped(2))
        guard case .blocked(let dirty) = UATGate.verdict(match: m, status: loaded("complete", .init(pass: 6)), committed: .notCommitted)
        else { Issue.record("expected blocked"); return }
        #expect(dirty == "UAT.md is not committed in the worktree")
        guard case .blocked(let partial) = UATGate.verdict(match: m, status: loaded("partial", .init(fail: 1, pending: 2)), committed: .committed)
        else { Issue.record("expected blocked"); return }
        #expect(partial.contains("1 fail") && partial.contains("2 pending"))
        guard case .blocked(let empty) = UATGate.verdict(match: m, status: loaded("partial", .init()), committed: .committed)
        else { Issue.record("expected blocked"); return }
        #expect(empty.contains("no items"))
        #expect(UATGate.verdict(match: m, status: .notStarted, committed: .committed) == .blocked("UAT not started: no UAT.md"))
        #expect(UATGate.verdict(match: m, status: .unreadable("x"), committed: .committed) == .blocked("UAT could not be read: x"))
        #expect(UATGate.verdict(match: m, status: loaded("complete", .init(pass: 1)), committed: .error("git timed out")) == .blocked("git timed out"))
    }

    @Test func onlyCompleteAndCommittedPass() {
        let statuses: [UATStatus.Outcome] = [
            .notStarted, .unreadable("x"), loaded("partial", .init()), loaded("partial", .init(pass: 3, skipped: 1)),
            loaded("partial", .init(fail: 1)), loaded("", .init(pass: 1)), loaded("weird", .init(pass: 1)),
            loaded("complete", .init(pass: 1)), loaded("complete", .init(skipped: 2)),
        ]
        let committeds: [UATGate.Committed] = [.committed, .notCommitted, .error("e")]
        for status in statuses {
            for committed in committeds {
                let verdict = UATGate.verdict(match: "3", status: status, committed: committed)
                var passes = false
                if verdict == .allowed { passes = true }
                if case .confirmSkipped = verdict { passes = true }
                var complete = false
                if case .loaded(let s) = status, s.result == "complete" { complete = true }
                #expect(passes == (complete && committed == .committed))
            }
        }
    }

    @Test func pressDecision() {
        #expect(UATGate.press(.notGated) == .proceed)
        #expect(UATGate.press(.allowed) == .proceed)
        #expect(UATGate.press(.confirmSkipped(2)) == .confirm(2))
        #expect(UATGate.press(.blocked("why")) == .stop("why"))
        #expect(UATGate.press(.checking) == .stop("checking UAT"))
    }
}
