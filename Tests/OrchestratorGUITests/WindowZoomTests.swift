import AppKit
import Testing
@testable import OrchestratorGUI

@Suite struct WindowZoomTests {
    let full = NSRect(x: 0, y: 25, width: 1000, height: 700)
    let small = NSRect(x: 100, y: 100, width: 400, height: 300)

    @Test func zoomsThenRestoresThePreviousFrame() {
        var toggle = ZoomToggle()
        #expect(toggle.next(current: small, full: full) == full)
        #expect(toggle.next(current: full, full: full) == small)
    }

    @Test func atFullWithNothingRememberedItShrinks() {
        var toggle = ZoomToggle()
        let frame = toggle.next(current: full, full: full)
        #expect(frame != full)
        #expect(full.contains(frame))
    }

    @MainActor @Test func windowAllowsFullScreen() {
        let window = NSWindow(contentRect: small, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.collectionBehavior = [.fullScreenNone]
        WindowChrome.allowFullScreen(window)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.collectionBehavior.contains(.fullScreenNone))
    }
}
