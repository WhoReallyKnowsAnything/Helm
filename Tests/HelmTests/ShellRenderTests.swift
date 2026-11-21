import AppKit
import SwiftUI
import Testing
@testable import Helm

@MainActor
struct ShellRenderTests {
    /// Draws the shell pane in the dark scheme and writes `screenshots/shell-dark.png` (the human-verify of the dark look).
    /// The app has no light scheme (`preferredColorScheme(.dark)` in `OrchestratorGUIApp.swift`, and
    /// `RenderSupport.render` forces dark), so no light snapshot exists (D-13). The start step is empty: no process forks.
    @Test func theShellPaneDrawsOnTheTerminalColour() throws {
        let size = CGSize(width: 600, height: 300)
        let rep = try RenderSupport.write(ShellPane(folder: NSHomeDirectory(), store: ShellStore(), start: { _ in }), .fixed(size), name: "shell-dark")
        #expect(CGFloat(rep.pixelsWide) >= size.width)
        #expect(CGFloat(rep.pixelsHigh) >= size.height)
        let pixel = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let want = try #require(Ink.terminalNS.usingColorSpace(.sRGB))
        #expect(abs(pixel.redComponent - want.redComponent) < 0.01)
        #expect(abs(pixel.greenComponent - want.greenComponent) < 0.01)
        #expect(abs(pixel.blueComponent - want.blueComponent) < 0.01)
    }
}
