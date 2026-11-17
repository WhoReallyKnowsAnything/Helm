import AppKit
import CoreGraphics
import SwiftUI

@MainActor
enum TestWindow {
    static func keyed(_ root: some View) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static func isOnScreen(_ window: NSWindow) -> Bool {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let screens = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
        let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains { entry in
            guard (entry[kCGWindowNumber as String] as? Int) == window.windowNumber,
                  (entry[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { return false }
            return screens.contains { $0.intersects(bounds) }
        }
    }
}
