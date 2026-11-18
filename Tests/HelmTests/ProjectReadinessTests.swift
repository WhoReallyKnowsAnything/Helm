import Foundation
import Testing
@testable import Helm

@Suite(.serialized) struct ProjectReadinessTests {
    private func tmux(_ socket: String, _ args: [String]) {
        guard let path = OrchestratorPaths.tmuxPath() else { return }
        _ = ProcessRunner.run(path, ["-L", socket] + args, environment: TmuxRunner.environment(socket: socket), timeout: 5)
    }

    private func name() -> String { "gui-test-\(UUID().uuidString.prefix(8).lowercased())" }

    @Test func aLiveDashboardIsReady() {
        let base = name(), socket = name()
        defer { tmux(socket, ["kill-server"]) }
        tmux(socket, ["new-session", "-d", "-s", base, "-n", "dashboard", "sleep 600"])
        #expect(ProjectReadiness.isReady(base: base, totalSeconds: 0.6, pollSeconds: 0.1, socket: socket))
    }

    @Test func aWindowThatExitsAtOnceIsNotReady() {
        let base = name(), socket = name()
        defer { tmux(socket, ["kill-server"]) }
        tmux(socket, ["new-session", "-d", "-s", base, "-n", "dashboard", "exit 1"])
        #expect(!ProjectReadiness.isReady(base: base, totalSeconds: 0.6, pollSeconds: 0.1, socket: socket))
    }

    @Test func aSessionWithoutADashboardWindowIsNotReady() {
        let base = name(), socket = name()
        defer { tmux(socket, ["kill-server"]) }
        tmux(socket, ["new-session", "-d", "-s", base, "-n", "other", "sleep 600"])
        #expect(!ProjectReadiness.isReady(base: base, totalSeconds: 0.3, pollSeconds: 0.1, socket: socket))
    }

    @Test func aMissingSessionIsNotReady() {
        #expect(!ProjectReadiness.isReady(base: name(), totalSeconds: 0.3, pollSeconds: 0.1, socket: name()))
    }

    @Test func paneDeadOutputIsParsed() {
        #expect(ProjectReadiness.paneAlive("0\n"))
        #expect(!ProjectReadiness.paneAlive("1\n"))
        #expect(!ProjectReadiness.paneAlive("0\n1\n"))
        #expect(!ProjectReadiness.paneAlive(""))
    }
}
