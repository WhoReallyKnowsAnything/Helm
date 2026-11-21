import AppKit
import SwiftUI
import Testing
@testable import Helm

@MainActor
struct ShellPaneTests {
    @Test func paneAsksItsSessionToStartInTheGivenFolder() {
        var seen: [ShellLaunch] = []
        let host = NSHostingView(rootView: ShellPane(folder: "/tmp", store: ShellStore(), start: { seen.append($0) }))
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

    @Test func removingThePaneKeepsTheShellAndShowingItAgainReusesIt() async throws {
        let store = ShellStore()
        let host = NSHostingView(rootView: AnyView(ShellPane(folder: NSTemporaryDirectory(), store: store)))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let session = store.session(for: NSTemporaryDirectory())
        let pid = session.pid
        #expect(pid > 0)
        session.view.feed(text: "KEPT-OUTPUT-MARK\r\n")
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        #expect(kill(pid, 0) == 0)
        host.rootView = AnyView(ShellPane(folder: NSTemporaryDirectory(), store: store))
        host.layoutSubtreeIfNeeded()
        #expect(store.session(for: NSTemporaryDirectory()) === session)
        #expect(String(decoding: session.view.getBufferAsData(), as: UTF8.self).contains("KEPT-OUTPUT-MARK"))
        store.stopAll()
        #expect(try await gone(pid))
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
