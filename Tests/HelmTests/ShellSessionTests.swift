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

    @Test func stopLiveEndsTheRealChildAndASecondCallIsSafe() async throws {
        let session = ShellSession()
        session.start(ShellLaunch(folder: NSTemporaryDirectory(), parentEnvironment: ProcessInfo.processInfo.environment))
        let pid = session.pid
        #expect(pid > 0)
        ShellSession.stopLive()
        ShellSession.stopLive()
        var gone = false
        for _ in 0..<50 where !gone {
            try await Task.sleep(for: .milliseconds(100))
            gone = kill(pid, 0) == -1 && errno == ESRCH
        }
        #expect(gone)
    }

    @Test func stopWithNothingStartedIsSafe() {
        let session = ShellSession(start: { _ in })
        session.stop()
        session.stop()
    }
}
