import Foundation
import Testing
@testable import OrchestratorGUI

struct ActiveLinesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let threshold = ActiveLines.activeSeconds

    private func worker(_ key: String, _ status: WorkerStatus) -> WorkerTreeNode {
        WorkerTreeNode(key: key, kind: .worker, title: key, taskTitle: nil, status: status)
    }

    private let orchestrator = WorkerTreeNode(key: WorkerTree.orchestratorKey, kind: .orchestrator, title: "o", taskTitle: nil, status: nil)

    private func entry(secondsAgo: Int) -> SessionStatusStore.Entry {
        .init(fold: SessionStatusFold(), modified: now.addingTimeInterval(-Double(secondsAgo)))
    }

    private func edge(_ from: String, _ to: String, _ kind: WorkerTreeEdge.Kind = .hierarchy) -> WorkerTreeEdge {
        WorkerTreeEdge(from: from, to: to, kind: kind)
    }

    private func resolve(_ nodes: [WorkerTreeNode], _ edges: [WorkerTreeEdge], _ log: [String: SessionStatusStore.Entry]) -> ActiveLines.Result {
        ActiveLines.resolve(nodes: nodes, edges: edges, log: log, now: now)
    }

    @Test func runningNodeWrittenTenSecondsAgoAnimatesItsEdges() {
        let e = edge("dashboard", "a")
        let r = resolve([orchestrator, worker("a", .running)], [e], ["a": entry(secondsAgo: 10)])
        #expect(r.nodes == ["a"])
        #expect(r.edges == [e])
    }

    @Test func thresholdEdge() {
        let e = edge("dashboard", "a")
        let nodes = [orchestrator, worker("a", .running)]
        #expect(resolve(nodes, [e], ["a": entry(secondsAgo: threshold)]).edges == [e])
        #expect(resolve(nodes, [e], ["a": entry(secondsAgo: threshold + 1)]).edges.isEmpty)
    }

    @Test func waitingFinishedAndStalledAreNeverActive() {
        for status in [WorkerStatus.waiting, .finished, .stalled] {
            let r = resolve([worker("a", status)], [edge("a", "b")], ["a": entry(secondsAgo: 1)])
            #expect(r.nodes.isEmpty && r.edges.isEmpty)
        }
    }

    @Test func aNodeWithNoLogIsStill() {
        #expect(resolve([worker("a", .running)], [edge("a", "b")], [:]).edges.isEmpty)
    }

    @Test func edgeAnimatesWhenEitherEndIsActive() {
        let nodes = [worker("a", .running), worker("b", .waiting), worker("c", .waiting)]
        let live = edge("b", "a", .dependency), idle = edge("b", "c", .dependency)
        #expect(resolve(nodes, [live, idle], ["a": entry(secondsAgo: 1)]).edges == [live])
    }

    @Test func orchestratorFollowsTheWriteTestOnly() {
        let edges = [edge("dashboard", "a"), edge("dashboard", "b")]
        let nodes = [orchestrator, worker("a", .finished), worker("b", .stalled)]
        let r = resolve(nodes, edges, ["dashboard": entry(secondsAgo: 2)])
        #expect(r.nodes == ["dashboard"])
        #expect(r.edges == edges)
        #expect(resolve(nodes, edges, ["dashboard": entry(secondsAgo: 31)]).nodes.isEmpty)
    }

    @Test func dashPhaseIsPeriodicAndMovesForward() {
        let t = Date(timeIntervalSinceReferenceDate: 1000.1)
        let p = ActiveLines.dashPhase(at: t, period: 1, cycle: 9)
        #expect(abs(ActiveLines.dashPhase(at: t.addingTimeInterval(1), period: 1, cycle: 9) - p) < 0.001)
        #expect(ActiveLines.dashPhase(at: t.addingTimeInterval(0.25), period: 1, cycle: 9) > p)
        #expect(p >= 0 && p < 9)
    }
}
