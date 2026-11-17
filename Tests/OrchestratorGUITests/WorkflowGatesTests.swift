import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct WorkflowGatesTests {
    typealias G = WorkflowGates

    private func status(_ phases: [(String, String)], cycle: String? = nil) -> CadenceStatus {
        CadenceStatus(current: phases.first { $0.1 != "complete" }?.0, total: phases.count, cycle: cycle,
                      phases: phases.map { .init(n: $0.0, name: "x", status: $0.1) }, cursorNext: nil)
    }

    @Test func nextStageFollowsTheStatus() {
        let unplanned = status([("1", "complete"), ("2", "unplanned")])
        #expect(G.nextStage(status: unplanned, hasContext: false, skipDiscuss: false) == .init(stage: .context, phase: "2", reason: nil))
        #expect(G.nextStage(status: unplanned, hasContext: true, skipDiscuss: false).stage == .plan)
        #expect(G.nextStage(status: unplanned, hasContext: false, skipDiscuss: true).stage == .plan)
        #expect(G.nextStage(status: status([("1", "planned")]), hasContext: true, skipDiscuss: false).stage == .execute)
        #expect(G.nextStage(status: status([("1", "executed")]), hasContext: true, skipDiscuss: false).stage == .verify)
    }

    @Test func allCompleteGivesMilestoneWithTheLastPhaseText() {
        let next = G.nextStage(status: status([("1", "complete"), ("2.1", "complete")]), hasContext: false, skipDiscuss: false)
        #expect(next.stage == .milestone)
        #expect(next.phase == "2.1")
    }

    @Test func closedMilestoneHasNoNextStage() {
        let next = G.nextStage(status: status([("1", "complete")], cycle: "none"), hasContext: false, skipDiscuss: false)
        #expect(next.stage == nil)
        #expect(next.reason != nil)
    }

    @Test func duplicateNumberHasNoNextStage() {
        let next = G.nextStage(status: status([("1", "complete"), ("1", "unplanned")]), hasContext: true, skipDiscuss: false)
        #expect(next.stage == nil)
        #expect(next.reason?.contains("1") == true)
    }

    @Test func g1BlocksPlanWithoutContextUnlessSkipDiscuss() {
        let s = status([("1", "unplanned")])
        guard case .blocked = G.verdict(for: .plan, status: s, hasContext: false, skipDiscuss: false, audit: nil) else {
            Issue.record("G1 should block"); return
        }
        #expect(G.verdict(for: .plan, status: s, hasContext: false, skipDiscuss: true, audit: nil) == .allowed)
        #expect(G.verdict(for: .plan, status: s, hasContext: true, skipDiscuss: false, audit: nil) == .allowed)
    }

    @Test func g2BlocksExecuteWhileUnplanned() {
        guard case .blocked = G.verdict(for: .execute, status: status([("1", "unplanned")]), hasContext: true, skipDiscuss: false, audit: nil) else {
            Issue.record("G2 should block"); return
        }
        #expect(G.verdict(for: .execute, status: status([("1", "planned")]), hasContext: true, skipDiscuss: false, audit: nil) == .allowed)
    }

    @Test func g4BlocksMilestoneOnBrokenOrFailedAudit() {
        let s = status([("1", "complete")])
        guard case .blocked(let reason) = G.verdict(for: .milestone, status: s, hasContext: true, skipDiscuss: false, audit: .success(12)) else {
            Issue.record("G4 should block"); return
        }
        #expect(reason.contains("12"))
        #expect(G.verdict(for: .milestone, status: s, hasContext: true, skipDiscuss: false, audit: .success(0)) == .allowed)
        guard case .blocked(let failed) = G.verdict(for: .milestone, status: s, hasContext: true, skipDiscuss: false,
                                                    audit: .failure(.init(reason: "boom"))) else {
            Issue.record("a failed audit should block"); return
        }
        #expect(failed.contains("boom"))
    }

    @Test func stageOrder() {
        #expect(G.Stage.context.following == .plan)
        #expect(G.Stage.verify.following == .milestone)
        #expect(G.Stage.milestone.following == nil)
    }
}
