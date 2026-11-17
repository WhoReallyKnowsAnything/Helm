import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct WorkflowOverlayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func stamp(secondsAgo: TimeInterval) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format.string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func row(_ label: String, _ status: String, event: String? = nil, age: TimeInterval = 3600) -> WorkerRow {
        WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: event, createdAt: stamp(secondsAgo: age))
    }

    private func derive(_ rows: [WorkerRow], live: Set<String> = [], phase: String = "1") -> WorkflowOverlay? {
        WorkflowOverlay.derive(phase: phase, rows: rows, liveLabels: live, now: now)
    }

    @Test func runningRowWithLiveLabelIsRunning() {
        let overlay = derive([row("cad-execute-p1", "running")], live: ["cad-execute-p1"])
        #expect(overlay?.state == .running && overlay?.text == "executing")
        #expect(derive([row("cad-context-p1", "running")], live: ["cad-context-p1"])?.text == "context running")
    }

    @Test func oldRunningRowWithNoLiveLabelIsDead() {
        #expect(derive([row("cad-plan-p1", "running")])?.state == .dead)
        #expect(derive([row("cad-plan-p1", "running")])?.text == "dead worker")
    }

    @Test func youngRunningRowWithNoLiveLabelIsStartingNotDead() {
        let overlay = derive([row("cad-verify-p1", "running", age: 2)])
        #expect(overlay?.state == .running && overlay?.text == "verify running")
    }

    @Test func doneRowWaitsForMergeWithOrWithoutLiveLabel() {
        #expect(derive([row("cad-execute-p1", "done")])?.state == .waitingForMerge)
        #expect(derive([row("cad-execute-p1", "done")], live: ["cad-execute-p1"])?.text == "waiting for merge")
        #expect(derive([row("cad-execute-p1", "running", event: "done")])?.state == .waitingForMerge)
    }

    @Test func mergedAndDeadRowsGiveNone() {
        #expect(derive([row("cad-execute-p1", "merged"), row("cad-plan-p1", "dead")]) == nil)
    }

    @Test func configLabelUsesTheStageRules() {
        func held(_ rows: [WorkerRow], live: Set<String> = []) -> WorkflowOverlay.State? {
            WorkflowOverlay.heldState(label: "cad-config", rows: rows, liveLabels: live, now: now)
        }
        #expect(held([row("cad-config", "running")], live: ["cad-config"]) == .running)
        #expect(held([row("cad-config", "running", age: 2)]) == .running)
        #expect(held([row("cad-config", "running")]) == .dead)
        #expect(held([row("cad-config", "done")]) == .waitingForMerge)
        #expect(held([row("cad-config", "merged")]) == nil)
        #expect(held([]) == nil)
    }

    @Test func phaseOneDoesNotReadPhaseOnePointOne() {
        #expect(derive([row("cad-execute-p1-1", "running")], live: ["cad-execute-p1-1"]) == nil)
        #expect(derive([row("cad-execute-p1-1", "running")], live: ["cad-execute-p1-1"], phase: "1.1")?.label == "cad-execute-p1-1")
    }

    @Test func precedenceIsWaitingThenRunningThenDead() {
        let rows = [row("cad-context-p1", "running"), row("cad-plan-p1", "running", age: 1), row("cad-execute-p1", "done")]
        #expect(derive(rows, live: ["cad-plan-p1"])?.state == .waitingForMerge)
        #expect(derive(Array(rows.prefix(2)), live: ["cad-plan-p1"])?.stage == .plan)
    }

    @Test func aLiveLabelWithNoRowIsRunning() {
        let overlay = derive([], live: ["cad-execute-p1"])
        #expect(overlay?.state == .running && overlay?.stage == .execute && overlay?.label == "cad-execute-p1")
        #expect(derive([], live: ["cad-execute-p1-1"]) == nil)
    }

    @Test func aLiveLabelWithNoRowDoesNotBeatAWaitingRow() {
        let rows = [row("cad-execute-p1", "done")]
        #expect(derive(rows, live: ["cad-plan-p1"])?.state == .waitingForMerge)
    }

    @Test func missingCreatedAtCountsAsOld() {
        let bare = WorkerRow(agentId: "cad-plan-p1", status: "running", taskTitle: nil, lastEvent: nil)
        #expect(derive([bare])?.state == .dead)
    }
}
