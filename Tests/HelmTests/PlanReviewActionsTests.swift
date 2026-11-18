import Foundation
import Testing
@testable import Helm

@Suite struct PlanReviewActionsTests {
    private func make(_ s: PlanReviewState, gate: String? = "advisory", notes: Bool = false) -> PlanReviewActions.Result {
        PlanReviewActions.make(state: s, gate: gate, notesInFlight: notes)
    }

    @Test func readyWithReviewPresentApproveOnNotesOn() {
        let r = make(.readyForReview(reviewInFlight: false))
        #expect(r.approve == PlanReviewActions.Button(enabled: true, reason: nil, needsConfirmation: false))
        #expect(r.notes?.enabled == true)
    }

    @Test func reviewInFlightAsksUntilConfirmed() throws {
        let approve = try #require(make(.readyForReview(reviewInFlight: true)).approve)
        #expect(approve.enabled && approve.needsConfirmation)
        #expect(PlanReviewActions.decide(approve, confirmed: false) == .ask)
        #expect(PlanReviewActions.decide(approve, confirmed: true) == .start)
    }

    @Test func directApproveStartsWithoutAsking() throws {
        let approve = try #require(make(.readyForReview(reviewInFlight: false)).approve)
        #expect(PlanReviewActions.decide(approve, confirmed: false) == .start)
    }

    @Test func workerEndedApproveOnNotesOff() {
        let done = make(.readyWorkerEnded(reviewInFlight: false))
        #expect(done.approve?.enabled == true && done.approve?.needsConfirmation == false)
        #expect(done.notes == .off("worker ended"))
        #expect(make(.readyWorkerEnded(reviewInFlight: true)).approve?.needsConfirmation == true)
    }

    @Test func didNotFinishBothOff() {
        let r = make(.didNotFinish)
        #expect(r.approve == .off("worker did not finish"))
        #expect(r.notes?.enabled == false)
        #expect(PlanReviewActions.decide(r.approve!, confirmed: true) == .refuse("worker did not finish"))
    }

    @Test func otherStatesBothOffWithReasons() {
        for s in [PlanReviewState.planRunning, .finishedNoPlanFiles, .noPlan] {
            let r = make(s)
            #expect(r.approve?.enabled == false && r.approve?.reason != nil)
            #expect(r.notes?.enabled == false && r.notes?.reason != nil)
        }
    }

    @Test func plannedHasNoButtons() {
        #expect(make(.planned) == PlanReviewActions.Result(approve: nil, notes: nil))
    }

    @Test func notesInFlightTurnsNotesOffAndApproveAsks() {
        let r = make(.readyForReview(reviewInFlight: true), notes: true)
        #expect(r.notes == .off("notes being applied"))
        #expect(r.approve?.enabled == true && r.approve?.needsConfirmation == true)
    }

    @Test func gateOffTurnsNotesOffNamingKeyAndLeavesApprove() {
        let r = make(.readyForReview(reviewInFlight: false), gate: "off")
        #expect(r.notes?.enabled == false)
        #expect(r.notes?.reason?.contains("review.triggers.plan.gate") == true)
        #expect(r.approve?.enabled == true)
    }

    @Test func pressCallsStartOnceWithLabelOnReadyPlan() throws {
        var calls: [String] = []
        let approve = try #require(make(.readyForReview(reviewInFlight: false)).approve)
        PlanReviewActions.press(approve, confirmed: false, label: "cad-plan-p4") { calls.append($0) }
        #expect(calls == ["cad-plan-p4"])
    }

    @Test func pressInFlightWaitsForConfirmationAndCancelNeverStarts() throws {
        var calls: [String] = []
        let approve = try #require(make(.readyForReview(reviewInFlight: true)).approve)
        #expect(PlanReviewActions.press(approve, confirmed: false, label: "cad-plan-p4") { calls.append($0) } == .ask)
        #expect(calls.isEmpty)
        PlanReviewActions.press(approve, confirmed: true, label: "cad-plan-p4") { calls.append($0) }
        #expect(calls == ["cad-plan-p4"])
    }

    @Test func pressOnDisabledApproveNeverStarts() throws {
        var calls: [String] = []
        let approve = try #require(make(.didNotFinish).approve)
        PlanReviewActions.press(approve, confirmed: true, label: "cad-plan-p4") { calls.append($0) }
        #expect(calls.isEmpty)
    }

    @Test func otherGateValuesLeaveNotesOn() {
        for gate in ["advisory", "blocking", nil] as [String?] {
            #expect(make(.readyForReview(reviewInFlight: false), gate: gate).notes?.enabled == true)
        }
    }
}
