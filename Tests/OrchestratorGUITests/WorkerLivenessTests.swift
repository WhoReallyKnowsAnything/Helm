import Foundation
import Testing
@testable import OrchestratorGUI

@Suite(.serialized) struct WorkerLivenessTests {
    private func tmux(_ socket: String, _ args: [String]) -> ProcessResult {
        guard let path = OrchestratorPaths.tmuxPath() else { return ProcessResult(status: -1, stdout: "", stderr: "") }
        return ProcessRunner.run(path, ["-L", socket] + args, environment: TmuxRunner.environment(), timeout: 5)
    }

    private func newSocket() -> String { "gui-test-\(UUID().uuidString.prefix(8).lowercased())" }

    @Test func parsesNamePidAndDeadFlag() {
        let found = WorkerLiveness.parse("dashboard\t12\t0\ncad-execute-p1\t34\t1\nbad line\n")
        #expect(found == [.init(name: "dashboard", pid: 12, paneDead: false), .init(name: "cad-execute-p1", pid: 34, paneDead: true)])
    }

    @Test func aDeadPaneOrAGonePidIsNotAlive() {
        #expect(!WorkerLiveness.isAlive(.init(name: "a", pid: getpid(), paneDead: true)))
        #expect(WorkerLiveness.isAlive(.init(name: "a", pid: getpid(), paneDead: false)))
        #expect(!WorkerLiveness.isAlive(.init(name: "a", pid: 0, paneDead: false)))
    }

    @Test func aWindowIsLiveUntilItIsKilledAndNamesMatchExactly() throws {
        let socket = newSocket()
        defer { _ = tmux(socket, ["kill-server"]) }
        _ = tmux(socket, ["new-session", "-d", "-s", "proj", "-n", "dashboard", "sleep 600"])
        _ = tmux(socket, ["new-window", "-t", "proj:", "-n", "cad-execute-p1", "sleep 600"])
        let live = try WorkerLiveness.liveLabels(base: "proj", socket: socket).get()
        #expect(live.contains("cad-execute-p1"))
        #expect(!live.contains("cad-execute-p1-1"))
        _ = tmux(socket, ["kill-window", "-t", "proj:cad-execute-p1"])
        #expect(try !WorkerLiveness.liveLabels(base: "proj", socket: socket).get().contains("cad-execute-p1"))
    }

    @Test func noSessionGivesAnEmptySet() throws {
        let socket = newSocket()
        defer { _ = tmux(socket, ["kill-server"]) }
        #expect(try WorkerLiveness.liveLabels(base: "proj", socket: socket).get().isEmpty)
        _ = tmux(socket, ["new-session", "-d", "-s", "other", "sleep 600"])
        #expect(try WorkerLiveness.liveLabels(base: "proj", socket: socket).get().isEmpty)
    }

    @Test func aBadTmuxPathGivesAnError() {
        guard case .failure = WorkerLiveness.liveLabels(base: "proj", socket: newSocket(), tmux: "/nonexistent/tmux") else {
            Issue.record("expected an error")
            return
        }
        guard case .failure = WorkerLiveness.liveLabels(base: "proj", socket: newSocket(), tmux: nil) else {
            Issue.record("expected an error")
            return
        }
    }
}
