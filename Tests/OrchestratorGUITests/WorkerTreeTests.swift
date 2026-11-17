import Foundation
import Testing
@testable import OrchestratorGUI

struct WorkerTreeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tree(_ state: WorkerState?) -> WorkerTree {
        WorkerTree(orchestratorTitle: "proj", state: state, log: [:], now: now)
    }

    /// A log entry folded from a turn fixture, written `secondsAgo` before `now`.
    private func entry(_ fixture: String, secondsAgo: Double = 1) throws -> SessionStatusStore.Entry {
        var fold = SessionStatusFold()
        fold.feed(try ConversationFixtures.lines(fixture))
        return SessionStatusStore.Entry(fold: fold, modified: now.addingTimeInterval(-secondsAgo))
    }

    private func fixtureState(_ fx: FixtureProject) -> WorkerState? {
        guard case .loaded(let loaded) = WorkerDatabase(project: fx.path).read() else { return nil }
        return loaded
    }

    @Test func fixtureGivesThreeWorkersFourHierarchyEdgesAndOneDependencyEdge() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let built = tree(fixtureState(fx))
        #expect(built.nodes.map(\.key) == ["dashboard", "alpha", "bravo", "charlie"])
        #expect(built.edges.filter { $0.kind == .hierarchy }.count == 3)
        let dependencies = built.edges.filter { $0.kind == .dependency }
        #expect(dependencies == [WorkerTreeEdge(from: "bravo", to: "alpha", kind: .dependency)])
        #expect(!built.edges.contains { $0.from == "alpha" && $0.to == "delta" })
        #expect(built.nodes.compactMap(\.status) == [.running, .waiting, .finished])
    }

    @Test func noDatabaseGivesTheOrchestratorOnly() {
        let built = tree(nil)
        #expect(built.nodes.map(\.kind) == [.orchestrator])
        #expect(built.edges.isEmpty)
    }

    @Test func orchestratorNodeExistsWithoutADashboardRow() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        try fx.sql("delete from sessions where agent_id='dashboard'")
        let built = tree(fixtureState(fx))
        #expect(built.nodes.contains { $0.key == "dashboard" && $0.kind == .orchestrator && $0.title == "proj" })
    }

    @Test func workersFollowCreatedAtThenAgentId() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        try fx.sql("""
            insert into sessions (agent_id, worktree_path, status, created_at) values
            ('zeta', '/fx/zeta', 'running', '2026-01-01 10:05:00'),
            ('echo', '/fx/echo', 'running', '2026-01-01 10:05:00');
            """)
        let built = tree(fixtureState(fx))
        #expect(built.nodes.filter { $0.kind == .worker }.map(\.key) == ["alpha", "bravo", "charlie", "echo", "zeta"])
    }

    @Test func aSelfDependencyDrawsNoEdge() {
        let row = WorkerRow(agentId: "a", status: "running", taskTitle: nil, lastEvent: nil)
        let state = WorkerState(rows: [row], dependencies: [WorkerDependency(dependent: "a", upstream: "a")])
        #expect(tree(state).edges.filter { $0.kind == .dependency }.isEmpty)
    }

    // The cyan rule (D-09).

    private func hold(_ label: String, _ state: GateHold.State = .live, id: String = "toolu_A") -> GateHold {
        GateHold(id: id, label: label, hash: String(repeating: "a", count: 64), epoch: 1, state: state, command: "Bash: git push")
    }

    private func row(_ label: String, status: String = "running", at activity: String? = nil, event: String? = nil) -> WorkerRow {
        var row = WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: event)
        row.lastActivityAt = activity
        return row
    }

    private func status(of label: String, rows: [WorkerRow], holds: [GateHold] = [], cover: BlockCover = BlockCover(),
                        log: [String: SessionStatusStore.Entry] = [:], dead: Set<String> = []) -> WorkerStatus? {
        WorkerTree(orchestratorTitle: "proj", state: WorkerState(rows: rows), log: log, now: now,
                   holds: holds, cover: cover, deadLabels: dead).nodes.first { $0.key == label }?.status
    }

    private func covered(_ rows: [WorkerRow], by holds: [GateHold]) -> BlockCover {
        var cover = BlockCover()
        cover.update(rows: rows, holds: holds)
        return cover
    }

    private func counts(_ rows: [WorkerRow], holds: [GateHold] = [], cover: BlockCover = BlockCover(),
                        log: [String: SessionStatusStore.Entry] = [:], dead: Set<String> = []) -> [Int] {
        let counts = WorkerTree(orchestratorTitle: "proj", result: .loaded(WorkerState(rows: rows)), log: log, now: now,
                                holds: holds, cover: cover, deadLabels: dead).counts
        return [counts.waiting, counts.running]
    }

    @Test func aDeadLabelShowsDeadWorkerAndCountsInNeither() {
        #expect(status(of: "a", rows: [row("a")], dead: ["a"]) == .dead)
        #expect(counts([row("a")], dead: ["a"]) == [0, 0])
        #expect(status(of: "a", rows: [row("a")]) == .running)
        #expect(counts([row("a")]) == [0, 1])
    }

    @Test func aLiveHoldBeatsADeadLabel() {
        #expect(status(of: "a", rows: [row("a")], holds: [hold("a")], dead: ["a"]) == .waiting)
    }

    @Test func theCountsTakeOnlyWaitingAndRunningWorkers() {
        let rows = [row("a"), row("b", status: "blocked", at: "t1"), row("c", status: "done"), row("d", status: "stalled")]
        #expect(counts(rows) == [1, 1])
    }

    @Test func aLiveHoldMakesTheWorkerWaitingNotRunningInTheCounts() {
        #expect(counts([row("a")], holds: [hold("a")]) == [1, 0])
    }

    @Test func aCoveredBlockCountsAsRunning() {
        let rows = [row("a", status: "blocked", at: "t1")]
        #expect(counts(rows, cover: covered(rows, by: [hold("a")])) == [0, 1])
    }

    @Test func noDataGivesZeroCounts() {
        for result in [WorkerRead.noDatabase, nil] {
            let tree = WorkerTree(orchestratorTitle: "proj", result: result, log: [:], now: now)
            #expect(tree.counts.waiting == 0 && tree.counts.running == 0)
        }
    }

    @Test func aWorkerMidTurnIsRunningAndAfterItsResultWaiting() throws {
        #expect(status(of: "a", rows: [row("a")], log: ["a": try entry("turn-mid")]) == .running)
        #expect(status(of: "a", rows: [row("a")], log: ["a": try entry("turn-done")]) == .waiting)
        #expect(counts([row("a")], log: ["a": try entry("turn-done")]) == [1, 0])
    }

    @Test func aWorkerWaitsAfterAnInterrupt() throws {
        #expect(status(of: "a", rows: [row("a")], log: ["a": try entry("turn-interrupt")]) == .waiting)
    }

    @Test func aQueuedTurnKeepsTheWorkerRunning() throws {
        #expect(status(of: "a", rows: [row("a")], log: ["a": try entry("turn-queued")]) == .running)
    }

    @Test func controlTrafficAfterATurnLeavesTheWorkerWaiting() throws {
        #expect(status(of: "a", rows: [row("a")], log: ["a": try entry("turn-control-only")]) == .waiting)
    }

    @Test func aLogWithNoTurnEventsStaysRunning() {
        var empty = SessionStatusFold()
        empty.feed([])
        let log = ["a": SessionStatusStore.Entry(fold: empty, modified: now)]
        #expect(status(of: "a", rows: [row("a")], log: log) == .running)
    }

    @Test func theTurnEndDoesNotCancelTheCoverRuleAndALiveHoldStillWaits() throws {
        let rows = [row("a", status: "blocked", at: "t1")]
        let log = ["a": try entry("turn-mid")]
        #expect(status(of: "a", rows: rows, cover: covered(rows, by: [hold("a")]), log: log) == .running)
        let done = ["a": try entry("turn-done")]
        #expect(status(of: "a", rows: rows, cover: covered(rows, by: [hold("a")]), log: done) == .waiting)
        #expect(status(of: "a", rows: [row("a")], holds: [hold("a")], log: log) == .waiting)
    }

    @Test func aRunningWorkerSilentForMoreThanTenMinutesIsStalledWhateverItsTurn() throws {
        #expect(status(of: "a", rows: [row("a")], log: ["a": try entry("turn-mid", secondsAgo: 601)]) == .stalled)
        #expect(status(of: "a", rows: [row("a")], log: ["a": try entry("turn-mid", secondsAgo: 599)]) == .running)
        #expect(status(of: "a", rows: [row("a")], log: ["a": try entry("turn-done", secondsAgo: 601)]) == .stalled)
    }

    @Test func aRunningWorkerWithALiveHoldCountsAsWaitingWhateverItsLastEvent() {
        #expect(counts([row("a", event: "start")], holds: [hold("a")]) == [1, 0])
    }

    @Test func aRunningWorkerWithAnyOtherLastEventStaysRunningWithoutALog() {
        for event in ["start", "commit", "busy", "idle", nil] {
            #expect(counts([row("a", event: event)]) == [0, 1])
        }
    }

    @Test func aRunningWorkerWithALiveHoldIsWaiting() {
        #expect(status(of: "a", rows: [row("a")], holds: [hold("a")]) == .waiting)
        #expect(status(of: "a", rows: [row("a")]) == .running)
    }

    @Test func aBlockedWorkerWithNoHoldIsWaiting() {
        #expect(status(of: "a", rows: [row("a", status: "blocked", at: "t1")]) == .waiting)
    }

    @Test func aBlockedWorkerWhoseBlockALiveHoldCoveredIsRunningOnceTheHoldIsGoneOrDecided() {
        let rows = [row("a", status: "blocked", at: "t1")]
        let cover = covered(rows, by: [hold("a")])
        #expect(status(of: "a", rows: rows, cover: cover) == .running)
        #expect(status(of: "a", rows: rows, holds: [hold("a", .decided)], cover: cover) == .running)
        #expect(status(of: "a", rows: rows, holds: [hold("a")], cover: cover) == .waiting)
    }

    @Test func aNewerLastActivityAtIsANewBlockAndStaysWaiting() {
        let cover = covered([row("a", status: "blocked", at: "t1")], by: [hold("a")])
        #expect(status(of: "a", rows: [row("a", status: "blocked", at: "t2")], cover: cover) == .waiting)
        #expect(status(of: "a", rows: [row("a", status: "blocked", at: nil)], cover: cover) == .waiting)
    }

    @Test func aRunningWorkerWithABlockedLastEventIsCoveredTheSameWay() {
        let rows = [row("a", status: "running", at: "t1", event: "blocked")]
        #expect(status(of: "a", rows: rows) == .waiting)
        #expect(status(of: "a", rows: rows, cover: covered(rows, by: [hold("a")])) == .running)
    }

    @Test(arguments: [GateHold.State.decided, .tampered, .ghost])
    func aBlockedWorkerWithOnlyAnUntrustedHoldFileAndNoCoverIsWaiting(state: GateHold.State) {
        let rows = [row("a", status: "blocked", at: "t1")]
        #expect(status(of: "a", rows: rows, holds: [hold("a", state)]) == .waiting)
        // A junk file never hides a wait, and a junk file never creates one.
        #expect(status(of: "a", rows: [row("a")], holds: [hold("a", state)]) == .running)
        #expect(covered(rows, by: [hold("a", state)]) == BlockCover())
    }

    @Test func aMergedWorkerWithALiveHoldHasNoNode() {
        #expect(status(of: "a", rows: [row("a", status: "merged")], holds: [hold("a")]) == nil)
        #expect(status(of: "a", rows: [row("a", status: "dead")], holds: [hold("a")]) == nil)
    }

    @Test func aHoldForAnUnknownLabelLeavesTheTreeEqualToTheTreeWithoutHolds() {
        let state = WorkerState(rows: [row("a"), row("b", status: "blocked", at: "t1")])
        let without = WorkerTree(orchestratorTitle: "proj", state: state, log: [:], now: now)
        let with = WorkerTree(orchestratorTitle: "proj", state: state, log: [:], now: now,
                              holds: [hold("ghost-label")], cover: covered(state.rows, by: [hold("ghost-label")]))
        #expect(with == without)
    }

    @Test func blockCoverStoresTheRowValueOnlyForLabelsWithALiveHold() {
        let rows = [row("a", at: "t1"), row("b", at: "t2"), row("c", at: nil)]
        var cover = BlockCover()
        cover.update(rows: rows, holds: [hold("a"), hold("c"), hold("b", .ghost)])
        #expect(cover.lastActivityAt(of: "a") == "t1")
        #expect(cover.lastActivityAt(of: "b") == nil)
        #expect(cover.lastActivityAt(of: "c") == nil)
        cover.update(rows: [row("a", at: "t3")], holds: [])
        #expect(cover.lastActivityAt(of: "a") == "t1")
        cover.update(rows: [row("a", at: "t3")], holds: [hold("a")])
        #expect(cover.lastActivityAt(of: "a") == "t3")
    }
}
