import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct ExecutePlanStateTests {
    private let waves = [["PLAN-1.md", "PLAN-2.md"], ["PLAN-3.md"], ["PLAN-4.md"]]

    private func resolve(_ file: String, _ statuses: [String: String], live: Bool) -> ExecutePlanState.Result {
        ExecutePlanState.resolve(file: file, waves: waves, statuses: statuses, live: live)
    }

    @Test func noReportRunsOnlyWhileLive() {
        #expect(resolve("PLAN-1.md", [:], live: true) == .init(state: .running, failure: false))
        #expect(resolve("PLAN-1.md", [:], live: false) == .init(state: .waiting, failure: false))
    }

    // User-directed (plan 2): several waves means a sequential run, so only the first incomplete plan runs.
    @Test func inASequentialRunOnlyTheFirstIncompletePlanRuns() {
        #expect(resolve("PLAN-2.md", [:], live: true).state == .waiting)
        let atCheckpoint = ["PLAN-1.md": "PLAN CHECKPOINT: structural"]
        #expect(resolve("PLAN-4.md", atCheckpoint, live: true).state == .waiting)
        #expect(resolve("PLAN-2.md", atCheckpoint, live: true).state == .waiting)
    }

    // D-02: one wave of several plans is a parallel batch, all dispatched together.
    @Test func aSingleWaveOfSeveralPlansRunsAsOneBatch() {
        let batch = [["PLAN-1.md", "PLAN-2.md", "PLAN-3.md"]]
        for file in batch[0] {
            #expect(ExecutePlanState.resolve(file: file, waves: batch, statuses: [:], live: true).state == .running)
            #expect(ExecutePlanState.resolve(file: file, waves: batch, statuses: [:], live: false).state == .waiting)
        }
    }

    @Test func noReportOutsideTheLowestIncompleteWaveStaysWaiting() {
        #expect(resolve("PLAN-3.md", [:], live: true).state == .waiting)
        let wave1Done = ["PLAN-1.md": "PLAN COMPLETE", "PLAN-2.md": "PLAN COMPLETE"]
        #expect(resolve("PLAN-3.md", wave1Done, live: true).state == .running)
        #expect(resolve("PLAN-4.md", wave1Done, live: true).state == .waiting)
    }

    @Test func doneIsNeverAFailure() {
        for live in [true, false] {
            #expect(resolve("PLAN-1.md", ["PLAN-1.md": "PLAN COMPLETE"], live: live) == .init(state: .done, failure: false))
        }
    }

    @Test func partialRunsWhenLiveAndFailsWhenDead() {
        let s = ["PLAN-1.md": "PLAN PARTIAL"]
        #expect(resolve("PLAN-1.md", s, live: true) == .init(state: .running, failure: false))
        #expect(resolve("PLAN-1.md", s, live: false) == .init(state: .partial, failure: true))
    }

    @Test func anUnrecognisedFirstLineIsTreatedAsPartial() {
        let s = ["PLAN-1.md": "something odd"]
        #expect(resolve("PLAN-1.md", s, live: false) == .init(state: .partial, failure: true))
        #expect(resolve("PLAN-1.md", s, live: true).state == .running)
    }

    @Test func onlyFourCheckpointTypesTakeAnAnswer() {
        for type in ["structural", "human-verify", "decision", "blocked"] { #expect(ExecutePlanState.takesAnswer(type)) }
        for type in ["suite-red", "Suite-Red", "", "other"] { #expect(!ExecutePlanState.takesAnswer(type)) }
    }

    @Test func checkpointFailureFollowsD11() {
        func check(_ type: String, live: Bool) -> ExecutePlanState.Result {
            resolve("PLAN-1.md", ["PLAN-1.md": "PLAN CHECKPOINT: \(type)"], live: live)
        }
        #expect(check("structural", live: false) == .init(state: .checkpoint("structural"), failure: true))
        #expect(check("blocked", live: true) == .init(state: .checkpoint("blocked"), failure: true))
        #expect(check("suite-red", live: true) == .init(state: .checkpoint("suite-red"), failure: false))
        #expect(check("structural", live: true) == .init(state: .checkpoint("structural"), failure: false))
    }
}
