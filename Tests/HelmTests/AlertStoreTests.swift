import Foundation
import Testing
@testable import Helm

/// What the two output closures received.
@MainActor private final class Collected {
    var alerts: [Alert] = []
    var counts: [Int] = []
}

/// A tmux listing that a test changes between refreshes. The runner reads it from another thread.
private final class Listing: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: TmuxOutcome
    init(_ outcome: TmuxOutcome) { self.outcome = outcome }
    var current: TmuxOutcome { lock.lock(); defer { lock.unlock() }; return outcome }
    func set(_ next: TmuxOutcome) { lock.lock(); outcome = next; lock.unlock() }
}

@Suite(.serialized) @MainActor struct AlertStoreTests {
    private func store(_ collected: Collected, makeSource: (@Sendable (String) -> WorkerSource)? = nil) -> AlertStore {
        let onAlert: (Alert) -> Void = { collected.alerts.append($0) }
        let onCount: (Int) -> Void = { collected.counts.append($0) }
        if let makeSource { return AlertStore(makeSource: makeSource, onAlert: onAlert, onCount: onCount) }
        return AlertStore(onAlert: onAlert, onCount: onCount)
    }

    private func project(_ id: String, _ fx: FixtureProject) -> AlertProject {
        AlertProject(id: id, folder: fx.path, title: "title-\(id)")
    }

    /// Long enough for a file event (0.2 s latency) plus a read, to show that nothing happened.
    private func quiet() async { try? await Task.sleep(for: .milliseconds(800)) }

    @Test func whatAlreadyExistsAtStartRaisesNothingAndIsCounted() async throws {
        let fx = try FixtureProject.make()
        let holds = FixtureHolds(fx)
        defer { holds.remove() }
        // bravo is blocked and has a live hold: it counts once. alpha is blocked with no hold: pane-blocked. charlie is finished.
        try holds.add(id: "h1", label: "bravo")
        try fx.sql("UPDATE sessions SET status = 'blocked' WHERE agent_id = 'alpha'")
        let seen = Collected()
        let alerts = store(seen)
        alerts.setProjects([project("p1", fx)])
        await settle { alerts.count == 2 }
        #expect(alerts.count == 2)
        #expect(seen.counts == [2])
        await quiet()
        #expect(seen.alerts.isEmpty)
        alerts.setProjects([])
    }

    @Test func aNewLiveHoldRaisesExactlyOneAlertWithin2Seconds() async throws {
        let fx = try FixtureProject.make()
        let holds = FixtureHolds(fx)
        defer { holds.remove() }
        let seen = Collected()
        let alerts = store(seen)
        alerts.setProjects([project("p1", fx)])
        await settle { alerts.count == 1 }
        try holds.add(id: "h2", label: "alpha", command: "git push origin main")
        await settle { !seen.alerts.isEmpty }
        await quiet()
        #expect(seen.alerts.map(\.kind) == [.hold])
        #expect(seen.alerts.first?.label == "alpha" && seen.alerts.first?.projectId == "p1")
        #expect(seen.alerts.first?.command == "Bash: git push origin main")
        #expect(alerts.count == 2)
        alerts.setProjects([])
    }

    @Test func aBlockedRowRaisesAnAlertOnlyWhenNoHoldFileExistsForItsLabel() async throws {
        let fx = try FixtureProject.make()
        let holds = FixtureHolds(fx)
        defer { holds.remove() }
        let seen = Collected()
        let alerts = store(seen)
        alerts.setProjects([project("p1", fx)])
        await settle { alerts.count == 1 }
        try holds.add(id: "h1", label: "alpha")
        await settle { seen.alerts.count == 1 }
        // alpha now has a live hold: marking its row blocked adds nothing.
        try fx.sql("UPDATE sessions SET status = 'blocked' WHERE agent_id = 'alpha'")
        await quiet()
        #expect(seen.alerts.map(\.kind) == [.hold])
        #expect(alerts.count == 2)
        // charlie has none: it is a real pane block.
        try fx.sql("UPDATE sessions SET status = 'blocked' WHERE agent_id = 'charlie'")
        await settle { seen.alerts.count == 2 }
        #expect(seen.alerts.map(\.kind) == [.hold, .blocked])
        #expect(seen.alerts.last?.label == "charlie")
        #expect(alerts.count == 3)
        alerts.setProjects([])
    }

    @Test func aWorkerEnteringFinishedRaisesOneFinishedAlert() async throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let seen = Collected()
        let alerts = store(seen)
        alerts.setProjects([project("p1", fx)])
        await settle { alerts.count == 1 }
        try fx.sql("UPDATE sessions SET last_event = 'done', last_activity_at = '2026-01-02 09:00:00' WHERE agent_id = 'alpha'")
        await settle { !seen.alerts.isEmpty }
        await quiet()
        #expect(seen.alerts.map(\.kind) == [.finished])
        #expect(seen.alerts.first?.label == "alpha")
        alerts.setProjects([])
    }

    @Test func aSecondProjectAddsToTheCountAndARemovedOneStopsItsEvents() async throws {
        let one = try FixtureProject.make(), two = try FixtureProject.make()
        let holdsTwo = FixtureHolds(two)
        defer { one.remove(); holdsTwo.remove() }
        let seen = Collected()
        let alerts = store(seen)
        alerts.setProjects([project("p1", one)])
        await settle { alerts.count == 1 }
        alerts.setProjects([project("p1", one), project("p2", two)])
        await settle { alerts.count == 2 }
        #expect(alerts.count == 2)
        #expect(seen.alerts.isEmpty)

        alerts.setProjects([project("p1", one)])
        #expect(alerts.count == 1)
        try holdsTwo.add(id: "h1", label: "alpha")
        await quiet()
        #expect(seen.alerts.isEmpty)
        #expect(alerts.count == 1)
        alerts.setProjects([])
        #expect(alerts.count == 0)
        #expect(seen.counts == [1, 2, 1, 0])
    }

    @Test func eachProjectHasItsOwnShareOfTheCount() async throws {
        let one = try FixtureProject.make(), two = try FixtureProject.make()
        let holdsOne = FixtureHolds(one)
        defer { holdsOne.remove(); two.remove() }
        // p1: a live hold on alpha plus the fixture's pane-blocked bravo. p2: its blocked row unblocked, so nothing waits.
        try holdsOne.add(id: "h1", label: "alpha")
        try two.sql("UPDATE sessions SET status = 'running' WHERE status = 'blocked'")
        let alerts = store(Collected())
        alerts.setProjects([project("p1", one), project("p2", two)])
        await settle { alerts.counts.count == 2 && alerts.count == 2 }
        #expect(alerts.counts == ["p1": 2, "p2": 0])
        alerts.setProjects([])
        #expect(alerts.counts.isEmpty)
    }

    /// A hold in an open project that is not the selected one raises that project's own badge count, and the count drops when the hold goes.
    @Test func aHoldInAnotherOpenProjectRaisesItsBadgeAndDropsWhenGone() async throws {
        let selected = try FixtureProject.make(), other = try FixtureProject.make()
        let holdsOther = FixtureHolds(other)
        defer { holdsOther.remove(); selected.remove(); other.remove() }
        try selected.sql("UPDATE sessions SET status = 'running' WHERE status = 'blocked'")
        try other.sql("UPDATE sessions SET status = 'running' WHERE status = 'blocked'")
        let alerts = store(Collected())
        alerts.setProjects([project("p1", selected), project("p2", other)])
        await settle { alerts.counts.count == 2 }
        #expect(alerts.counts == ["p1": 0, "p2": 0])
        try holdsOther.add(id: "h1", label: "alpha")
        await settle { alerts.counts["p2"] == 1 }
        #expect(alerts.counts == ["p1": 0, "p2": 1])
        // Decided: the same hold now has a `.decision` file, so it no longer counts.
        try holdsOther.add(id: "h1", label: "alpha", decision: { "allow \($0)\n" })
        await settle { alerts.counts["p2"] == 0 }
        #expect(alerts.counts["p2"] == 0)
        alerts.setProjects([])
    }

    @Test func followingTheSessionStoreWatchesEachSessionWithADashboardWindowAndDropsGoneOnes() async throws {
        let a = try FixtureProject.make(), b = try FixtureProject.make(), c = try FixtureProject.make()
        defer { a.remove(); b.remove(); c.remove() }
        // Every fixture has 1 blocked worker with no hold, so each watched project adds 1 to the count.
        let both = TmuxOutcome.listed(
            sessions: "a\t\nb\t\nc\t\n",
            windows: "a\tdashboard\t\(a.path)\t%1\na\tbravo\t\(a.path)\t%4\nb\tdashboard\t\(b.path)\t%2\nb\tbravo\t\(b.path)\t%5\nc\tmain\t\(c.path)\t%3\n")
        let listing = Listing(both)
        let sessions = SessionStore { listing.current }
        let seen = Collected()
        let alerts = store(seen)
        alerts.follow(sessions)
        await sessions.refresh()
        await settle { alerts.count == 2 }
        await quiet()
        #expect(alerts.count == 2)

        listing.set(.listed(sessions: "a\t\nc\t\n", windows: "a\tdashboard\t\(a.path)\t%1\na\tbravo\t\(a.path)\t%4\nc\tmain\t\(c.path)\t%3\n"))
        await sessions.refresh()
        await settle { alerts.count == 1 }
        #expect(alerts.count == 1)
        #expect(seen.alerts.isEmpty)
        listing.set(.noServer)
        await sessions.refresh()
        #expect(alerts.count == 0)
    }

    @Test func aProjectThatCannotBeReadRaisesNothingAndItsFirstGoodReadIsAQuietBaseline() async throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let source = FakeSource([.permissionDenied])
        let seen = Collected()
        let alerts = store(seen, makeSource: { _ in source })
        alerts.setProjects([project("p1", fx)])
        await settle { source.reads >= 1 }
        await quiet()
        #expect(alerts.count == 0)

        let busy = WorkerState(rows: [
            WorkerRow(agentId: "a", status: "blocked", taskTitle: nil, lastEvent: nil),
            WorkerRow(agentId: "b", status: "running", taskTitle: nil, lastEvent: "done"),
        ])
        source.set([.loaded(busy)])
        try fx.sql("UPDATE sessions SET retry_count = retry_count + 1")
        await settle { alerts.count == 1 }
        await quiet()
        #expect(alerts.count == 1)
        #expect(seen.alerts.isEmpty)
        alerts.setProjects([])
    }
}
