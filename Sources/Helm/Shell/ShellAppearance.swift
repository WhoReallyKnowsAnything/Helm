import AppKit
import SwiftTerm

/// The shell view look. Every value comes from a DesignKit token (D-12).
enum ShellAppearance {
    static func apply(to view: TerminalView) {
        let size = Metric.terminalFontSize
        view.font = NSFont(name: Metric.terminalFontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        // SwiftTerm's default derives colours 16-255 from the 16 base colours, which is duller than the xterm table.
        view.ansi256PaletteStrategy = .xterm
        view.installColors(Ink.terminalPaletteNS.map(terminalColor))
        view.nativeBackgroundColor = Ink.terminalNS
        view.nativeForegroundColor = Ink.terminalTextNS
    }

    private static func terminalColor(_ color: NSColor) -> SwiftTerm.Color {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> UInt16 { UInt16((min(max(v, 0), 1) * 255).rounded()) }
        return SwiftTerm.Color(red8: byte(c.redComponent), green8: byte(c.greenComponent), blue8: byte(c.blueComponent))
    }
}
