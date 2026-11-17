import XCTest
@testable import OrchestratorGUI

final class CadenceChipsTests: XCTestCase {
    private func row(_ n: String, _ stage: WorkflowStage) -> WorkflowBoard.Row {
        .init(n: n, name: "p", display: .stage(stage))
    }

    private func chips(_ rows: [WorkflowBoard.Row] = [], next: WorkflowGates.Next? = nil, drift: Int = 0,
                       suggest: [CadenceSuggest.Entry] = [], decisions: [String: Int] = [:]) -> [CadenceChip] {
        CadenceChips.make(rows: rows, next: next, drift: drift, suggest: suggest, decisions: decisions,
                          reviewerModel: "sonnet", reviewerEffort: "medium")
    }

    func testVerifyPhaseGivesCoverageAndMinimalism() {
        let result = chips([row("2", .verify), row("3", .planned)])
        XCTAssertEqual(result.map(\.skill), ["/cadence:cad-coverage", "/cadence:cad-minimalism-review"])
        XCTAssertEqual(result.map(\.phase), ["2", "2"])
        XCTAssertNil(result[0].innerRole)
        XCTAssertEqual(result[1].innerRole, "cad-reviewer: sonnet / medium")
    }

    func testSuggestOnlyForSuggestEntries() {
        XCTAssertTrue(chips().isEmpty)
        let result = chips(suggest: [.init(subject: "a", evidence: "e")])
        XCTAssertEqual(result.map(\.skill), ["/cadence:cad-suggest"])
        XCTAssertEqual(result[0].rule, "a: e")
    }

    func testTwoSuggestEntriesGiveOneChipWithUniqueLabels() {
        let result = chips([row("2", .verify)], drift: 1,
                           suggest: [.init(subject: "cad-executor", evidence: "ev1"), .init(subject: "cad-executor", evidence: "ev2")])
        XCTAssertEqual(result.filter { $0.skill == "/cadence:cad-suggest" }.count, 1)
        let rule = result.first { $0.skill == "/cadence:cad-suggest" }?.rule ?? ""
        XCTAssertTrue(rule.contains("ev1") && rule.contains("ev2"))
        XCTAssertEqual(rule, "cad-executor: ev1; cad-executor: ev2")
        XCTAssertEqual(Set(result.map(\.label)).count, result.count)
    }

    func testIdenticalSuggestEntriesGiveTheTextOnce() {
        let entry = CadenceSuggest.Entry(subject: "cad-executor", evidence: "33 checkpoint return(s) - plans may exceed one context")
        let result = chips(suggest: [entry, entry]).filter { $0.skill == "/cadence:cad-suggest" }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].rule, "cad-executor: 33 checkpoint return(s) - plans may exceed one context")
    }

    func testHealthNeedsDrift() {
        XCTAssertTrue(chips(drift: 0).isEmpty)
        XCTAssertEqual(chips(drift: 1).map(\.skill), ["/cadence:cad-health"])
    }

    func testAuditFollowsMilestoneAsNextStage() {
        XCTAssertEqual(chips(next: .init(stage: .milestone, phase: "3", reason: nil)).map(\.skill), ["/cadence:cad-audit"])
        XCTAssertTrue(chips(next: .init(stage: .verify, phase: "3", reason: nil)).isEmpty)
        XCTAssertTrue(chips(next: .init(stage: .milestone, phase: "3", reason: nil))[0].rule.hasPrefix("board rule"))
    }

    func testEveryPhaseCompleteGivesAuditAndClosedMilestoneGivesNone() {
        let done = [CadenceStatus.Phase(n: "1", name: "a", status: "complete")]
        let open = CadenceStatus(current: nil, total: 1, cycle: nil, phases: done, cursorNext: nil)
        let closed = CadenceStatus(current: nil, total: 1, cycle: "none", phases: done, cursorNext: nil)
        let openNext = WorkflowGates.nextStage(status: open, hasContext: true, skipDiscuss: false)
        let closedNext = WorkflowGates.nextStage(status: closed, hasContext: true, skipDiscuss: false)
        XCTAssertEqual(chips(next: openNext).map(\.skill), ["/cadence:cad-audit"])
        XCTAssertNil(closedNext.stage)
        XCTAssertTrue(chips(next: closedNext).isEmpty)
    }

    func testDecisionReviewForPlannedPhaseWithDecisionsAndItStaysOnRepeat() {
        let rows = [row("1.1", .planned)]
        let first = chips(rows, decisions: ["1.1": 2])
        XCTAssertEqual(first.map(\.skill), ["/cadence:cad-decision-review"])
        XCTAssertEqual(first[0].phase, "1.1")
        XCTAssertEqual(first[0].argument, ".planning/phases/1.1/CONTEXT.md")
        XCTAssertEqual(first[0].label, "cad-decision-review-p1-1")
        XCTAssertEqual(chips(rows, decisions: ["1.1": 2]), first)
        XCTAssertTrue(chips(rows, decisions: ["1.1": 0]).isEmpty)
        XCTAssertTrue(chips([row("1.1", .executing)], decisions: ["1.1": 2]).isEmpty)
    }

    func testDurableCountOnlyUnderItsHeading() {
        let text = "## Decisions\n- D-09 (x): a\n## Durable decisions\n- D-01 (a): b\n- D-02 (c): d\n  - D-03 (n)\nprose\n## Other\n- D-04 (z)\n"
        XCTAssertEqual(CadenceChips.durableDecisionCount(in: text), 2)
        XCTAssertEqual(CadenceChips.durableDecisionCount(in: "## Decisions\n- D-09 (x)\n"), 0)
    }
}
