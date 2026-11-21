import AppKit
import SwiftUI
import Testing
@testable import Helm

@MainActor @Suite(.serialized)
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
        #expect(await waitFor { window.firstResponder is NSTextView })
    }

    private func waitFor(timeout: Duration = .seconds(2), _ what: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !what(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        return what()
    }

    private func box(enabled: Bool, yields: Bool, shown: String = "") -> PromptBoxView {
        PromptBoxView(text: .constant(""), entries: [], enabled: enabled, message: nil, onSend: {}, yieldsFocus: yields, shown: shown)
    }

    /// Selecting another project or node reuses the box with new content: onAppear does not fire, so the shown identity must claim.
    @Test func switchingTheShownSessionTakesFocus() async throws {
        _ = NSApplication.shared
        let window = TestWindow.keyed(box(enabled: true, yields: false, shown: "project-a/node-1"))
        try await Task.sleep(for: .milliseconds(300))
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!(window.firstResponder is NSTextView))
        settle(window, box(enabled: true, yields: false, shown: "project-a/node-2")) // node switch
        #expect(await waitFor { window.firstResponder is NSTextView })
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(100))
        settle(window, box(enabled: true, yields: false, shown: "project-b/node-1")) // project switch
        #expect(await waitFor { window.firstResponder is NSTextView })
    }

    /// A card that holds the keyboard keeps it across a switch.
    @Test func switchingTheShownSessionKeepsACardsFocus() async throws {
        _ = NSApplication.shared
        let window = TestWindow.keyed(box(enabled: true, yields: true, shown: "a"))
        try await Task.sleep(for: .milliseconds(300))
        settle(window, box(enabled: true, yields: true, shown: "b"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!(window.firstResponder is NSTextView))
    }

    /// The hosting view's rootView is updated, not replaced: a new hosting view would fire onAppear and hide the bug.
    private func settle(_ window: NSWindow, _ root: PromptBoxView) {
        (window.contentView as? NSHostingView<PromptBoxView>)?.rootView = root
    }

    /// A box that appears disabled and is enabled later (the session's inbox appears) must take focus then.
    @Test func aBoxThatBecomesEnabledTakesFocus() async throws {
        _ = NSApplication.shared
        let window = TestWindow.keyed(box(enabled: false, yields: false))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!(window.firstResponder is NSTextView))
        settle(window, box(enabled: true, yields: false))
        #expect(await waitFor { window.firstResponder is NSTextView })
    }

    /// A card holds the keyboard while it shows: when it is answered, the box takes the focus back.
    @Test func aBoxThatStopsYieldingTakesFocus() async throws {
        _ = NSApplication.shared
        let window = TestWindow.keyed(box(enabled: true, yields: true))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!(window.firstResponder is NSTextView))
        settle(window, box(enabled: true, yields: false))
        #expect(await waitFor { window.firstResponder is NSTextView })
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

    private func mouseUp() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    /// The click that activates the app arrives after `didBecomeActive` and moves focus under the pointer: its mouse up claims again.
    @Test func theActivatingClickClaimsFocusAgain() async throws {
        let reclaim = PromptBoxView.ClickReclaim()
        var claims = 0
        reclaim.install { claims += 1 }
        defer { reclaim.remove() }
        reclaim.activated()
        NSApp.sendEvent(mouseUp())
        try await Task.sleep(for: .milliseconds(100))
        #expect(claims == 1)
        NSApp.sendEvent(mouseUp())
        try await Task.sleep(for: .milliseconds(100))
        #expect(claims == 1) // only the first click after activation
    }

    /// A click with no activation before it, or long after it, must not pull focus off what the user selected.
    @Test func otherClicksDoNotClaimFocus() async throws {
        let reclaim = PromptBoxView.ClickReclaim()
        var claims = 0
        reclaim.install { claims += 1 }
        defer { reclaim.remove() }
        NSApp.sendEvent(mouseUp())
        reclaim.activated(at: Date(timeIntervalSinceNow: -(PromptBoxView.ClickReclaim.window + 1)))
        NSApp.sendEvent(mouseUp())
        try await Task.sleep(for: .milliseconds(100))
        #expect(claims == 0)
    }

    /// AppKit selects all text on focus, so the next key would replace a kept draft: the claim leaves the caret at the end.
    @Test func aClaimWithADraftPutsTheCaretAtTheEndWithoutSelection() async throws {
        _ = NSApplication.shared
        let draft = "half typed"
        let box = PromptBoxView(text: .constant(draft), entries: [], enabled: true, message: nil, onSend: {})
        let window = TestWindow.keyed(box)
        try await Task.sleep(for: .milliseconds(300))
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(100))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(300))
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: (draft as NSString).length, length: 0))
    }
}
