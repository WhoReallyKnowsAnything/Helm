import AppKit
import SwiftUI
import Testing
@testable import Helm

@MainActor
struct ActivationFocusTests {
    /// Activating the app can make the window key after `didBecomeActive` fired, so the box also claims on key.
    @Test func theWindowBecomingKeyFocusesTheBoxAgain() async throws {
        _ = NSApplication.shared
        let box = PromptBoxView(text: .constant(""), entries: [], enabled: true, message: nil, onSend: {})
        let window = TestWindow.keyed(box)
        try await Task.sleep(for: .milliseconds(300))
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(100))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(300))
        #expect(window.firstResponder is NSTextView)
    }

    @Test func theBoxTestWindowIsNeverVisibleToTheOwner() async throws {
        _ = NSApplication.shared
        let box = PromptBoxView(text: .constant(""), entries: [], enabled: true, message: nil, onSend: {})
        let window = TestWindow.keyed(box)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!TestWindow.isOnScreen(window))
    }

    /// A report still pending when the view leaves its window must not run: the box's state may be gone by then.
    @Test func aReportPendingWhenTheViewIsRemovedNeverFires() async throws {
        var reports: [NSWindow?] = []
        let window = TestWindow.keyed(Color.clear)
        let reporter = HostWindow.Reporter { reports.append($0) }
        window.contentView = reporter
        window.contentView = NSView()
        try await Task.sleep(for: .milliseconds(200))
        #expect(reports.isEmpty)
    }

    @Test func aReportPendingWhenTheWindowClosesNeverFires() async throws {
        var reports: [NSWindow?] = []
        let window = TestWindow.keyed(Color.clear)
        window.isReleasedWhenClosed = false
        window.contentView = HostWindow.Reporter { reports.append($0) }
        window.close()
        try await Task.sleep(for: .milliseconds(200))
        #expect(reports.isEmpty)
    }

    @Test func aViewThatStaysInItsWindowReportsIt() async throws {
        var reports: [NSWindow?] = []
        let window = TestWindow.keyed(Color.clear)
        window.contentView = HostWindow.Reporter { reports.append($0) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(reports.count == 1 && reports[0] === window)
    }

    /// Only the window the reporter sits in now may flag it as closing: an old window's observer is removed on move and on detach.
    @Test func onlyTheCurrentWindowsCloseFlagsTheReporter() {
        let first = TestWindow.keyed(Color.clear), second = TestWindow.keyed(Color.clear), third = TestWindow.keyed(Color.clear)
        for window in [first, second, third] { window.isReleasedWhenClosed = false }
        let reporter = HostWindow.Reporter { _ in }
        first.contentView = reporter
        second.contentView = reporter
        first.close()
        #expect(!reporter.closing)
        second.contentView = NSView()
        second.close()
        #expect(!reporter.closing)
        third.contentView = reporter
        third.close()
        #expect(reporter.closing)
    }

    /// The read-only transcript text view often holds the focus and always holds text: it must not count as a half-typed message.
    @Test func aSelectableTranscriptHoldingFocusDoesNotBlockTheClaim() async throws {
        _ = NSApplication.shared
        let window = TestWindow.keyed(Color.clear)
        let transcript = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.string = "an earlier reply"
        window.contentView = transcript
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(transcript))
        try await Task.sleep(for: .milliseconds(100))
        #expect(CardKeys.mayClaimFocus(in: window))
        #expect(!CardKeys.fieldIsEditing(in: window))
    }

    @Test func aHalfTypedEditableMessageStillBlocksTheClaim() async throws {
        _ = NSApplication.shared
        let window = TestWindow.keyed(Color.clear)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        field.isEditable = true
        field.string = "half typed"
        window.contentView = field
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(field))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!CardKeys.mayClaimFocus(in: window))
        #expect(CardKeys.fieldIsEditing(in: window))
    }

    @Test func aKeyNotificationClaimsOnlyForTheBoxsOwnWindow() {
        let own = NSWindow(), other = NSWindow()
        #expect(PromptBoxView.mayClaimOnKey(enabled: true, yieldsFocus: false, became: own, host: own))
        #expect(!PromptBoxView.mayClaimOnKey(enabled: true, yieldsFocus: false, became: other, host: own))
        #expect(!PromptBoxView.mayClaimOnKey(enabled: true, yieldsFocus: false, became: own, host: nil))
        #expect(!PromptBoxView.mayClaimOnKey(enabled: true, yieldsFocus: true, became: own, host: own))
        #expect(!PromptBoxView.mayClaimOnKey(enabled: false, yieldsFocus: false, became: own, host: own))
    }
}
