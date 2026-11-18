import Foundation
import Testing
@testable import Helm

private func hold(_ id: String, _ label: String, _ state: GateHold.State = .live, command: String = "Bash: git push") -> GateHold {
    GateHold(id: id, label: label, hash: String(repeating: "a", count: 64), epoch: 100, state: state, command: command)
}

private func row(_ label: String, _ status: String = "running", event: String? = nil, at: String? = nil) -> WorkerRow {
    WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: event, lastActivityAt: at)
}

private func snap(_ project: String = "p", holds: [GateHold] = [], rows: [WorkerRow] = []) -> AlertSnapshot {
    AlertSnapshot(projectId: project, projectTitle: "Title \(project)", holds: holds, rows: rows)
}

struct AlertTrackerTests {
    @Test func aBlockedRowWithNoLiveWindowRaisesNothingAndCountsNothing() {
        var tracker = AlertTracker()
        var base = snap(rows: [row("a")])
        base.liveWindows = ["a"]
        _ = tracker.ingest(base)
        var gone = snap(rows: [row("a", "blocked", at: "t1")])
        gone.liveWindows = ["dashboard"]
        #expect(tracker.ingest(gone).isEmpty)
        #expect(tracker.count == 0)
        var here = snap(rows: [row("a", "blocked", at: "t1")])
        here.liveWindows = ["a"]
        #expect(tracker.ingest(here).map(\.kind) == [.blocked])
        #expect(tracker.count == 1)
    }

    @Test func firstSnapshotRaisesNothingAndCountsHoldsAndPaneBlocks() {
        var tracker = AlertTracker()
        let alerts = tracker.ingest(snap(holds: [hold("h1", "a"), hold("h2", "a")],
                                         rows: [row("b", "blocked"), row("c", event: "done")]))
        #expect(alerts.isEmpty)
        #expect(tracker.count == 3)
    }

    @Test func aNewLiveHoldRaisesOnceAndTheSameSnapshotAgainRaisesNothing() {
        var tracker = AlertTracker()
        let first = [hold("h1", "a"), hold("h2", "a")]
        let rows = [row("a"), row("b", "blocked"), row("c", event: "done")]
        _ = tracker.ingest(snap(holds: first, rows: rows))
        let added = tracker.ingest(snap(holds: first + [hold("h3", "a", command: "Bash: rm -rf x")], rows: rows))
        #expect(added.map(\.kind) == [.hold])
        #expect(added[0].label == "a" && added[0].projectId == "p" && added[0].projectTitle == "Title p")
        #expect(added[0].command == "Bash: rm -rf x")
        #expect(tracker.count == 4)
        #expect(tracker.ingest(snap(holds: first + [hold("h3", "a")], rows: rows)).isEmpty)
    }

    @Test func aHoldThatDisappearsAndReturnsRaisesOnlyOnce() {
        var tracker = AlertTracker()
        _ = tracker.ingest(snap(rows: [row("a")]))
        #expect(tracker.ingest(snap(holds: [hold("h1", "a")], rows: [row("a")])).count == 1)
        #expect(tracker.ingest(snap(rows: [row("a")])).isEmpty)
        #expect(tracker.ingest(snap(holds: [hold("h1", "a")], rows: [row("a")])).isEmpty)
    }

    @Test func aBlockThatALiveHoldCoveredIsNotNewWhenTheHoldGoesButANewerOneIs() {
        var tracker = AlertTracker()
        _ = tracker.ingest(snap(rows: [row("a")]))
        _ = tracker.ingest(snap(holds: [hold("h1", "a")], rows: [row("a", "blocked", at: "t1")]))
        #expect(tracker.count == 1)
        let answered = tracker.ingest(snap(rows: [row("a", "blocked", at: "t1")]))
        #expect(answered.isEmpty)
        #expect(tracker.count == 0)
        let next = tracker.ingest(snap(rows: [row("a", "blocked", at: "t2")]))
        #expect(next.map(\.kind) == [.blocked] && next[0].label == "a")
        #expect(tracker.count == 1)
    }

    @Test func aTamperedHoldDoesNotHideAPaneBlock() {
        var tracker = AlertTracker()
        _ = tracker.ingest(snap(rows: [row("a")]))
        let alerts = tracker.ingest(snap(holds: [hold("h1", "a", .tampered)], rows: [row("a", "blocked", at: "t1")]))
        #expect(alerts.map(\.kind) == [.blocked])
        #expect(tracker.count == 1)
    }

    @Test func aGhostHoldDoesNotHideAPaneBlock() {
        var tracker = AlertTracker()
        _ = tracker.ingest(snap(rows: [row("a")]))
        let alerts = tracker.ingest(snap(holds: [hold("h1", "a", .ghost)], rows: [row("a", "blocked", at: "t1")]))
        #expect(alerts.map(\.kind) == [.blocked])
        #expect(tracker.count == 1)
    }

    @Test func aDecidedHoldFileIsCoveredOnlyWhenALiveHoldCoveredTheBlock() {
        var covered = AlertTracker()
        _ = covered.ingest(snap(rows: [row("a")]))
        _ = covered.ingest(snap(holds: [hold("h1", "a")], rows: [row("a", "blocked", at: "t1")]))
        let after = covered.ingest(snap(holds: [hold("h1", "a", .decided)], rows: [row("a", "blocked", at: "t1")]))
        #expect(after.isEmpty)
        #expect(covered.count == 0)

        var bare = AlertTracker()
        _ = bare.ingest(snap(rows: [row("a")]))
        let alerts = bare.ingest(snap(holds: [hold("h1", "a", .decided)], rows: [row("a", "blocked", at: "t1")]))
        #expect(alerts.map(\.kind) == [.blocked])
        #expect(bare.count == 1)
    }

    @Test func aBlockedRowWithoutAnyValueIsNeverCovered() {
        var tracker = AlertTracker()
        _ = tracker.ingest(snap(rows: [row("a")]))
        _ = tracker.ingest(snap(holds: [hold("h1", "a")], rows: [row("a", "blocked")]))
        #expect(tracker.ingest(snap(rows: [row("a", "blocked")])).map(\.kind) == [.blocked])
        #expect(tracker.count == 1)
    }

    @Test func aWorkerEnteringFinishedRaisesOnceAndANewValueRaisesAgain() {
        var tracker = AlertTracker()
        _ = tracker.ingest(snap(rows: [row("a"), row("c", event: "done", at: "t0")]))
        #expect(tracker.ingest(snap(rows: [row("a", event: "done", at: "t1"), row("c", event: "done", at: "t0")])).map(\.kind) == [.finished])
        #expect(tracker.ingest(snap(rows: [row("a", event: "done", at: "t1"), row("c", event: "done", at: "t0")])).isEmpty)
        #expect(tracker.ingest(snap(rows: [row("a", event: "done", at: "t2"), row("c", event: "done", at: "t0")])).map(\.kind) == [.finished])
        #expect(tracker.count == 0)
    }

    @Test func aBlockedRowIsNotFinishedAndAMergedRowIsHidden() {
        var tracker = AlertTracker()
        _ = tracker.ingest(snap(rows: [row("a"), row("m")]))
        let alerts = tracker.ingest(snap(rows: [row("a", "done", event: "done", at: "t1"), row("m", "merged", event: "blocked")]))
        #expect(alerts.isEmpty)
        #expect(tracker.count == 0)
    }

    @Test func aLaterProjectGetsItsOwnSilentBaselineAndRemovingItLowersTheCount() {
        var tracker = AlertTracker()
        _ = tracker.ingest(snap("p", holds: [hold("h1", "a")], rows: [row("a")]))
        #expect(tracker.count == 1)
        let joined = tracker.ingest(snap("q", holds: [hold("h9", "z")], rows: [row("y", "blocked")]))
        #expect(joined.isEmpty)
        #expect(tracker.count == 3)
        tracker.remove(project: "q")
        #expect(tracker.count == 1)
        // Back again: a fresh baseline, so what it already holds raises nothing.
        #expect(tracker.ingest(snap("q", holds: [hold("h9", "z")], rows: [row("y", "blocked")])).isEmpty)
        #expect(tracker.count == 3)
    }
}
