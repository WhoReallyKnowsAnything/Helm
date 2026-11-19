import AppKit
import SwiftUI
import Testing
@testable import Helm

@MainActor
struct ShellPaneTests {
    @Test func paneAsksItsSessionToStartInTheGivenFolder() {
        var seen: [ShellLaunch] = []
        let host = NSHostingView(rootView: ShellPane(folder: "/tmp", start: { seen.append($0) }))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(seen.count == 1)
        #expect(seen.first?.folder == "/tmp")
        #expect(seen.first?.arguments == ["-l"])
    }

    private func gone(_ pid: pid_t) async throws -> Bool {
        for _ in 0..<50 {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func removingThePaneEndsTheShell() async throws {
        let host = NSHostingView(rootView: AnyView(ShellPane(folder: NSTemporaryDirectory())))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let pid = ShellSession.live?.pid ?? 0
        #expect(pid > 0)
        #expect(kill(pid, 0) == 0)
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        #expect(try await gone(pid))
    }

    @Test func startingASecondSessionEndsTheFirst() async throws {
        let launch = ShellLaunch(folder: NSTemporaryDirectory(), parentEnvironment: ProcessInfo.processInfo.environment)
        let first = ShellSession()
        first.start(launch)
        let second = ShellSession()
        second.start(launch)
        #expect(try await gone(first.pid))
        #expect(kill(second.pid, 0) == 0)
        second.stop()
    }

    @Test func aNewSessionShowsNothingOfAnEarlierOne() async throws {
        let first = ShellSession()
        first.start(ShellLaunch(folder: NSTemporaryDirectory(), parentEnvironment: ProcessInfo.processInfo.environment))
        first.view.feed(text: "EARLIER-OUTPUT-MARK\r\n")
        first.stop()
        let second = ShellSession(start: { _ in })
        let text = String(decoding: second.view.getBufferAsData(), as: UTF8.self)
        #expect(!text.contains("EARLIER-OUTPUT-MARK"))
    }
}
