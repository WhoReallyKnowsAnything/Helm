import SwiftUI

/// Zoom toggle state: first call goes to the full frame and remembers where the window was, the next goes back.
/// At launch the window already fills the screen, so with nothing remembered the way back is an inset frame.
struct ZoomToggle {
    private(set) var previous: NSRect?

    mutating func next(current: NSRect, full: NSRect) -> NSRect {
        if current.equalTo(full) {
            defer { previous = nil }
            return previous ?? full.insetBy(dx: full.width * 0.15, dy: full.height * 0.15)
        }
        previous = current
        return full
    }
}

enum WindowChrome {
    private static var toggles: [ObjectIdentifier: ZoomToggle] = [:]

    /// The green button, View > Enter Full Screen and Ctrl-Cmd-F need this behaviour on the window.
    @MainActor static func allowFullScreen(_ window: NSWindow) {
        window.collectionBehavior.remove([.fullScreenNone, .fullScreenAuxiliary, .fullScreenDisallowsTiling])
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    /// Works whatever "Double-click a window's title bar to" is set to. Does nothing in full screen.
    @MainActor static func toggleZoom(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
        let key = ObjectIdentifier(window)
        var toggle = toggles[key] ?? ZoomToggle()
        window.setFrame(toggle.next(current: window.frame, full: screen.visibleFrame), display: true, animate: true)
        toggles[key] = toggle
    }
}

/// Put behind a band: a double-click on empty band space zooms the window. Controls in front keep their own clicks.
struct ZoomOnDoubleClick: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClickView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ClickView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let window { WindowChrome.toggleZoom(window) } else { super.mouseDown(with: event) }
        }
    }
}
