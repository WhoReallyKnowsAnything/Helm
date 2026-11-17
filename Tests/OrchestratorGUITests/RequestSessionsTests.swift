import Foundation
import Testing
@testable import OrchestratorGUI

@MainActor
struct RequestSessionsTests {
    private let ask = #"{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[]},"tool_use_id":"t1"}}"#

    private func row(_ id: String, out: String?, inbox: String? = "/tmp/in.jsonl") -> WorkerRow {
        WorkerRow(agentId: id, status: "working", taskTitle: nil, lastEvent: nil, inboxPath: inbox, outPath: out)
    }

    private func log(_ text: String) throws -> String {
        let path = NSTemporaryDirectory() + "gui-test-rs-" + UUID().uuidString.prefix(8).lowercased() + ".jsonl"
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func aRootSessionAlsoFollowsItsLoadedWorkers() {
        let state = WorkerState(rows: [row("w1", out: "/tmp/w1.out"), row("old", out: nil)])
        let keys = RequestSessions.selected(isRoot: true, state: state, live: { _ in true }).map(\.nodeKey)
        #expect(keys == [WorkerTree.orchestratorKey, "w1"])
    }

    @Test func aRootSessionWithoutLoadedStateFollowsOnlyTheDashboard() {
        #expect(RequestSessions.selected(isRoot: true, state: nil, live: { _ in true }).map(\.nodeKey) == [WorkerTree.orchestratorKey])
    }

    @Test func otherProjectsWorkersAreTaggedWithTheirFolderAndSkipRowsWithoutPaths() {
        let states = ["/p/a": WorkerState(rows: [row("w1", out: "/tmp/a.out"), row("old", out: nil)]),
                      "/p/b": WorkerState(rows: [row("w1", out: "/tmp/b.out")])]
        let sessions = RequestSessions.others(states, excluding: "/p/b")
        #expect(sessions.map(\.project) == ["/p/a"])
        #expect(sessions.map(\.nodeKey) == ["/p/a|w1"])
    }

    private func home() throws -> String {
        let dir = NSTemporaryDirectory() + "gui-test-home-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: dir + "/.claude/sessions/dashboard", withIntermediateDirectories: true)
        return dir
    }

    private func pendingCount(rootState: WorkerState?, otherOut: String) async throws -> [String: Int] {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let others = ["/p/other": WorkerState(rows: [row("w1", out: otherOut)])]
        let store = RequestStore()
        store.setSessions(RequestSessions.all(hasSelection: true, isRoot: true, state: rootState, live: { _ in true },
                                              states: others, folder: "/p/root", home: home))
        try await wait { !store.entries.isEmpty }
        return store.pendingByProject
    }

    @Test func withARootSessionSelectedAQuestionInAnotherOpenProjectIsCounted() async throws {
        let out = try log(ask + "\n")
        defer { try? FileManager.default.removeItem(atPath: out) }
        #expect(try await pendingCount(rootState: WorkerState(rows: []), otherOut: out) == ["/p/other": 1])
    }

    @Test func withARootSessionWhoseOwnStateIsNotLoadedYetAQuestionInAnotherProjectIsStillCounted() async throws {
        let out = try log(ask + "\n")
        defer { try? FileManager.default.removeItem(atPath: out) }
        #expect(try await pendingCount(rootState: nil, otherOut: out) == ["/p/other": 1])
    }

    @Test func aQuestionFromAnotherProjectIsCountedButNotInTheSelectedProjectsEntries() async throws {
        let out = try log(ask + "\n")
        defer { try? FileManager.default.removeItem(atPath: out) }
        let store = RequestStore()
        store.setSessions([.init(nodeKey: "/p/a|w1", outPath: out, inboxPath: "/tmp/in.jsonl", live: false, project: "/p/a")])
        try await wait { !store.entries.isEmpty }
        #expect(store.entries.first?.request.toolName == "AskUserQuestion")
        #expect(store.currentEntries.isEmpty)
        #expect(store.pendingByProject == ["/p/a": 1])
    }
}
