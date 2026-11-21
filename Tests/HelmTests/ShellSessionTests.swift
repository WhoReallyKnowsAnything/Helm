import Foundation
import Testing
@testable import Helm

@MainActor
struct ShellSessionTests {
    @Test func injectedStartReceivesTheLaunchAndForksNothing() {
        var seen: [ShellLaunch] = []
        let session = ShellSession(start: { seen.append($0) })
        session.start(ShellLaunch(folder: "/tmp", parentEnvironment: [:]))
        #expect(seen.count == 1)
        #expect(seen.first?.folder == "/tmp")
        #expect(seen.first?.arguments == ["-l"])
        #expect(session.pid == 0)
    }

    @Test func stopEndsTheRealChild() async throws {
        let folder = NSTemporaryDirectory()
        let session = ShellSession()
        session.start(ShellLaunch(folder: folder, parentEnvironment: ProcessInfo.processInfo.environment))
        let pid = session.pid
        #expect(pid > 0)
        #expect(kill(pid, 0) == 0)
        session.stop()
        session.stop()
        var gone = false
        for _ in 0..<50 where !gone {
            try await Task.sleep(for: .milliseconds(100))
            gone = kill(pid, 0) == -1 && errno == ESRCH
        }
        #expect(gone)
    }

    private func gone(_ pid: pid_t) async throws -> Bool {
        for _ in 0..<50 {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func storeReusesTheSessionPerFolderAndKeepsFoldersApart() async throws {
        let store = ShellStore()
        let a = store.session(for: "/tmp")
        #expect(store.session(for: "/tmp") === a)
        let b = store.session(for: NSTemporaryDirectory() + "/")
        #expect(b !== a)
        let (apid, bpid) = (a.pid, b.pid)
        #expect(apid > 0 && bpid > 0)
        store.stopAll()
        #expect(try await gone(apid))
        #expect(try await gone(bpid))
    }

    @Test func clearEndsTheShellAndTheNextRequestStartsAFreshOne() async throws {
        let store = ShellStore()
        let first = store.session(for: "/tmp")
        let pid = first.pid
        #expect(pid > 0)
        store.close("/tmp")
        #expect(try await gone(pid))
        let second = store.session(for: "/tmp")
        #expect(second !== first)
        #expect(second.pid > 0 && second.pid != pid)
        store.stopAll()
    }

    @Test func stopAllEndsEveryRealChildAndASecondCallIsSafe() async throws {
        let store = ShellStore()
        let pids = ["/tmp", NSTemporaryDirectory()].map { store.session(for: $0).pid }
        #expect(pids.allSatisfy { $0 > 0 })
        store.stopAll()
        store.stopAll()
        for pid in pids { #expect(try await gone(pid)) }
    }

    @Test func stopWithNothingStartedIsSafe() {
        let session = ShellSession(start: { _ in })
        session.stop()
        session.stop()
    }
}
