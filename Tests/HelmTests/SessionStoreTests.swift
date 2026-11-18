import Foundation
import Testing
@testable import Helm

/// Counts runner calls from a @Sendable closure.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

@Suite(.serialized) @MainActor struct SessionStoreTests {
    private func tmux(_ socket: String, _ args: [String]) {
        guard let path = OrchestratorPaths.tmuxPath() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-L", socket] + args
        p.environment = TmuxRunner.environment(socket: socket)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    @Test func realTmuxGivesOneRowAndWindowsInTheSameSnapshot() async throws {
        let prefix = "gui-test-\(UUID().uuidString.prefix(8).lowercased())"
        let a = "\(prefix)-a", b = "\(prefix)-b"
        let dir = NSTemporaryDirectory() + "\(prefix)/proj-a"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let socket = prefix
        defer {
            tmux(socket, ["kill-server"])
            try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + prefix)
        }
        tmux(socket, ["new-session", "-d", "-s", a, "-n", "dashboard", "-c", dir, "sleep 600"])
        tmux(socket, ["new-session", "-d", "-t", "=\(a)", "-s", "\(a)-dashboard"])
        tmux(socket, ["new-session", "-d", "-s", b, "-n", "main", "sleep 600"])

        let store = SessionStore { TmuxRunner.live(socket: socket) }
        await store.refresh()
        let mine = store.rows.filter { $0.id.hasPrefix(prefix) }
        #expect(mine == [SessionRow(id: a, title: "proj-a")])
        let dashboard = try #require(store.snapshot.windows.first { $0.session == a && $0.name == "dashboard" })
        #expect(dashboard.paneId.range(of: "^%[0-9]+$", options: .regularExpression) != nil)
        #expect(store.snapshot.windows.contains { $0.session == b && $0.name == "main" })
        #expect(store.snapshot.sessions.contains { $0.name == "\(a)-dashboard" && $0.group == a })

        tmux(socket, ["kill-session", "-t", "=\(a)"])
        await store.refresh()
        #expect(store.rows.filter { $0.id.hasPrefix(prefix) }.isEmpty)
    }

    @Test func nonServerFailureKeepsLastGoodDataAndSetsFailure() async {
        let calls = Calls()
        let store = SessionStore {
            calls.next() == 1
                ? .listed(sessions: "foo\t\n", windows: "foo\tdashboard\t/Users/x/foo\t%1\n")
                : .failed("boom")
        }
        await store.refresh()
        let first = store.snapshot
        #expect(first.rows == [SessionRow(id: "foo", title: "foo")])
        #expect(store.failure == nil)
        await store.refresh()
        #expect(store.snapshot == first)
        #expect(store.failure == "boom")
    }

    @Test func noServerMessagesAreRecognised() {
        #expect(TmuxRunner.isNoServer("no server running on /private/tmp/tmux-501/default"))
        #expect(TmuxRunner.isNoServer("error connecting to /private/tmp/tmux-501/default (No such file or directory)"))
        #expect(!TmuxRunner.isNoServer("unknown option"))
    }

    @Test func argsStartWithSocketFlagWhenSocketIsSet() {
        #expect(TmuxRunner.args(["list-sessions"], socket: "orch-test") == ["-L", "orch-test", "list-sessions"])
    }

    @Test func argsAreUnchangedWithoutSocket() {
        #expect(TmuxRunner.args(["list-sessions"], socket: nil) == ["list-sessions"])
    }

    @Test func environmentCarriesSocketOnlyWhenSet() {
        #expect(TmuxRunner.environment(socket: "orch-test")["ORCH_TMUX_SOCKET"] == "orch-test")
        #expect(TmuxRunner.environment(socket: nil) == ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"])
    }

    @Test func everyRefreshRaisesTheTickEvenWhenTheSnapshotIsUnchanged() async {
        let store = SessionStore { .listed(sessions: "foo\t\n", windows: "foo\tdashboard\t/p\t%1\n") }
        #expect(store.tick == 0)
        await store.refresh()
        let first = store.snapshot
        await store.refresh()
        #expect(store.snapshot == first)
        #expect(store.tick == 2)
    }

    @Test func noServerEmptiesRowsWithoutFailure() async {
        let calls = Calls()
        let store = SessionStore {
            calls.next() == 1 ? .listed(sessions: "foo\t\n", windows: "foo\tdashboard\t/p\t%1\n") : .noServer
        }
        await store.refresh()
        #expect(!store.rows.isEmpty)
        await store.refresh()
        #expect(store.snapshot == TmuxSnapshot())
        #expect(store.failure == nil)
    }
}
