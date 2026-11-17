import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct PlanReviewStateTests {
    private func make(_ o: WorkflowOverlay.State?, alive: Bool = true, planned: Bool = false, files: Bool = true,
                      review: Bool = false, notes: Bool = false) -> PlanReviewState {
        .make(overlay: o, alive: alive, planned: planned, hasPlanFiles: files, reviewExists: review, notesInFlight: notes)
    }

    @Test func runningIsPlanRunningLiveOrStarting() {
        #expect(make(.running) == .planRunning)
        #expect(make(.running, alive: false) == .planRunning)
    }

    @Test func startingRowIsNeverDidNotFinish() {
        let now = Date()
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let row = WorkerRow(agentId: "cad-plan-p4", status: "running", taskTitle: nil, lastEvent: nil,
                            createdAt: format.string(from: now.addingTimeInterval(-2)))
        let overlay = WorkflowOverlay.state(of: row, live: false, now: now)
        #expect(overlay == WorkflowOverlay.State.running)
        #expect(make(overlay, alive: false) == .planRunning)
    }

    @Test func waitingAliveFilesPresent() {
        #expect(make(.waitingForMerge) == .readyForReview(reviewInFlight: true))
        #expect(make(.waitingForMerge, review: true) == .readyForReview(reviewInFlight: false))
    }

    @Test func waitingNotAliveFilesPresent() {
        #expect(make(.waitingForMerge, alive: false) == .readyWorkerEnded(reviewInFlight: true))
        #expect(make(.waitingForMerge, alive: false, review: true) == .readyWorkerEnded(reviewInFlight: false))
    }

    @Test func waitingWithNoFiles() {
        #expect(make(.waitingForMerge, files: false) == .finishedNoPlanFiles)
    }

    @Test func deadIsDidNotFinishEvenWithFiles() {
        #expect(make(.dead) == .didNotFinish)
    }

    @Test func noOverlayDependsOnStage() {
        #expect(make(nil, planned: true) == .planned)
        #expect(make(nil, planned: false) == .noPlan)
    }

    @Test func notesInFlightKeepsReviewInFlightWhenReviewExists() {
        #expect(make(.waitingForMerge, review: true, notes: true) == .readyForReview(reviewInFlight: true))
        #expect(make(.waitingForMerge, alive: false, review: true, notes: true) == .readyWorkerEnded(reviewInFlight: true))
    }

    @Test func textsMatchThePlan() {
        #expect(PlanReviewState.planRunning.text == "Plan running")
        #expect(PlanReviewState.readyForReview(reviewInFlight: false).text == "Plan ready for review")
        #expect(PlanReviewState.readyWorkerEnded(reviewInFlight: false).text == "Plan ready for review, worker ended")
        #expect(PlanReviewState.didNotFinish.text == "worker did not finish")
        #expect(PlanReviewState.planned.text == "Planned")
        #expect(PlanReviewState.finishedNoPlanFiles.text == "No plan files in the worktree")
    }
}
