import AppKit
import SwiftUI

// The three token layers of design/KIT.md. Dark only (D-07).

// MARK: Layer 1, palette. Raw colours named by hue and step. Only the meaning layer below reads this enum.

enum Palette {
    private static func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let black = ns(0x000000)
    static let white = ns(0xFFFFFF)
    // Neutral greys of the Terminal craft look (D-13a).
    static let gray950 = ns(0x0E0E0F)
    static let gray900 = ns(0x121213)
    static let gray850 = ns(0x161617)
    static let gray825 = ns(0x1C1C1E)
    static let gray800 = ns(0x212123)
    static let gray750 = ns(0x2A2A2C)
    static let gray700 = ns(0x48484C)
    static let gray500 = ns(0x9A9A9E)
    static let gray300 = ns(0xC9C9CC)
    static let gray100 = ns(0xE6E6E8)
    static let gray600 = ns(0x6B727B)
    static let gray400 = ns(0x9AA3AD)
    static let cyan400 = ns(0x3CC8D8)
    static let blue400 = ns(0x5AA2FF)
    // Node card fills for running and waiting: the artboard fills offset from the grey node fill (D-13a).
    static let blueFill = ns(0x111825)
    static let cyanFill = ns(0x101C21)

    // Accent shades: step 600 is the fill, step 300 is the accent text in dark mode.
    static let lime400 = ns(0xC5E478)
    static let blue600 = ns(0x2F6CC0)
    static let blue300 = ns(0x8DB6EC)
    static let indigo600 = ns(0x4F55C7)
    static let indigo300 = ns(0xA3A8F0)
    static let purple600 = ns(0x8444C0)
    static let purple300 = ns(0xC5A1EA)
    static let pink600 = ns(0xC03F7F)
    static let pink300 = ns(0xEBA0C6)
    static let red600 = ns(0xC0392F)
    static let red300 = ns(0xEE9F98)
    static let yellow600 = ns(0xE0B400)
    static let yellow300 = ns(0xF3D966)
    static let green600 = ns(0x2E8B4A)
    static let green300 = ns(0x8FD6A4)
    static let mint600 = ns(0x3CC0A0)
    static let mint300 = ns(0xA3EAD6)
    static let graphite600 = ns(0x5A6068)
    static let graphite300 = ns(0xB4BAC1)

    // Fills of the conversation diff lines, offset from the panel grey like the node card fills.
    static let greenFill = ns(0x12261A)
    static let redFill = ns(0x2C1614)
}

// MARK: Layer 2, meaning. Parts read only this layer.

/// The colours of one accent: the fill, the accent text on dark surfaces and the text on the fill.
struct AccentSwatch {
    let fill: Color
    let text: Color
    let onAccent: Color

    init(fill: NSColor, text: NSColor, darkOnFill: Bool = false) {
        self.fill = Color(nsColor: fill)
        self.text = Color(nsColor: text)
        onAccent = Color(nsColor: darkOnFill ? Ink.onAccentDarkNS : Palette.white)
    }
}

enum Ink {
    /// The sidebar colour as NSColor, for the window behind the transparent title bar.
    static let sidebarNS = Palette.gray900
    /// Text on a light accent fill (lime, yellow and mint): the ground.
    static let onAccentDarkNS = Palette.gray950

    static let background = Color(nsColor: Palette.gray950)
    static let sidebar = Color(nsColor: sidebarNS)
    static let header = sidebar
    static let panel = Color(nsColor: Palette.gray850)
    static let terminal = Color(nsColor: Palette.black)
    static let border = Color(nsColor: Palette.gray750)
    /// Strong borders and tree lines.
    static let borderStrong = Color(nsColor: Palette.gray700)
    static let text = Color(nsColor: Palette.gray100)
    // D-13 calls #C9C9CC "muted text" and #9A9A9E "secondary text"; the role names stay so no call site changes.
    static let textSecondary = Color(nsColor: Palette.gray300)
    static let muted = Color(nsColor: Palette.gray500)
    /// The fill of the selected sidebar row.
    static let selectedRow = Color(nsColor: Palette.gray825)
    /// The dots of the grid behind the tree.
    static let dotGrid = Color(nsColor: Palette.gray800)
    /// The fill of a running node card.
    static let runningFill = Color(nsColor: Palette.blueFill)
    /// The fill of a waiting node card.
    static let waitingFill = Color(nsColor: Palette.cyanFill)
    /// An added and a removed line of a diff: the fill and the text on it.
    static let diffAddedFill = Color(nsColor: Palette.greenFill)
    static let diffAddedText = Color(nsColor: Palette.green300)
    static let diffRemovedFill = Color(nsColor: Palette.redFill)
    static let diffRemovedText = Color(nsColor: Palette.red300)
    /// The fill of a code block.
    static let codeFill = Color(nsColor: Palette.gray825)
    /// The fill of a `you` row in the conversation: lighter than the ground.
    static let youRowFill = Color(nsColor: Palette.gray825)
    /// The fill of a `claude` row in the conversation: darker than the ground.
    static let claudeRowFill = Color(nsColor: Palette.gray900)
    /// The glyph of a finished tool line.
    static let toolDone = Color(nsColor: Palette.green300)
    /// The glyph of a failed tool line.
    static let toolFailed = Color(nsColor: Palette.red300)
    /// Syntax colours of the editor, one per tokenizer role. Comments use the muted grey.
    static let syntaxKeyword = Color(nsColor: Palette.purple300)
    static let syntaxString = Color(nsColor: Palette.green300)
    static let syntaxComment = muted
    static let syntaxNumber = Color(nsColor: Palette.yellow300)
    static let syntaxKey = Color(nsColor: Palette.blue300)
    static let syntaxHeading = Color(nsColor: Palette.pink300)

    // Status colours (D-07). Fixed: the accent choice never changes them.
    /// Only for what waits on the user.
    static let waiting = Color(nsColor: Palette.cyan400)
    static let running = Color(nsColor: Palette.blue400)
    static let merged = Color(nsColor: Palette.gray400)
    static let stalled = Color(nsColor: Palette.gray600)

    /// The default accent. Views get the stored choice from the environment (`Accent.swift`).
    static let accent = swatch(for: .default)

    /// The only place an accent choice turns into colours. Nothing else resolves through the choice.
    static func swatch(for choice: AccentChoice) -> AccentSwatch {
        switch choice {
        case .lime: return AccentSwatch(fill: Palette.lime400, text: Palette.lime400, darkOnFill: true)
        case .blue: return AccentSwatch(fill: Palette.blue600, text: Palette.blue300)
        case .indigo: return AccentSwatch(fill: Palette.indigo600, text: Palette.indigo300)
        case .purple: return AccentSwatch(fill: Palette.purple600, text: Palette.purple300)
        case .pink: return AccentSwatch(fill: Palette.pink600, text: Palette.pink300)
        case .red: return AccentSwatch(fill: Palette.red600, text: Palette.red300)
        case .yellow: return AccentSwatch(fill: Palette.yellow600, text: Palette.yellow300, darkOnFill: true)
        case .green: return AccentSwatch(fill: Palette.green600, text: Palette.green300)
        case .mint: return AccentSwatch(fill: Palette.mint600, text: Palette.mint300, darkOnFill: true)
        case .graphite: return AccentSwatch(fill: Palette.graphite600, text: Palette.graphite300)
        }
    }
}

// MARK: Layer 3, scales.

enum Metric {
    static let corner: CGFloat = 3
    /// Width of the sidebar splitter, inherited from v1.
    static let splitter: CGFloat = 5
    static let headerBar: CGFloat = 36
    static let dispatchBar: CGFloat = 30
    static let hairline: CGFloat = 1
    /// Width of the label column at the left of a conversation row.
    static let gutter: CGFloat = 56
    /// Vertical inset of a `tools` row. Board C value, off the `Space` scale.
    static let toolsInset: CGFloat = 6
    /// Gap between tool lines in a `tools` row. Board C value, off the `Space` scale.
    static let toolLineGap: CGFloat = 2
    /// Width of the accent edge of the selected sidebar row.
    static let selectedEdge: CGFloat = 2
    /// Pitch and dot size of the grid behind the tree.
    static let dotPitch: CGFloat = 16
    static let dotSize: CGFloat = 2
    static let statusDot: CGFloat = 8
    /// Height of a button.
    static let control: CGFloat = 24
    static let focusRing: CGFloat = 2
    /// Minimum size of the main window.
    static let windowMinWidth: CGFloat = 760
    static let windowMinHeight: CGFloat = 480

    // The worker tree (`TreeLayout`), inherited from v1.
    static let nodeWidth: CGFloat = 260
    static let nodeHeight: CGFloat = 170
    static let nodeGapX: CGFloat = 16
    static let nodeGapY: CGFloat = 52
    static let treeMargin: CGFloat = 10
    /// Room taken from the node width before a title is measured (v1: 5 each side).
    static let nodeTitlePadding: CGFloat = 10
    static let nodeMinWidth: CGFloat = 80
    static let nodeMinHeight: CGFloat = 48
    static let nodeMaxWidth: CGFloat = 320
    static let nodeMaxHeight: CGFloat = 200
    /// The invisible square at a node's bottom-right corner that resizes it.
    static let resizeHandle: CGFloat = 16
    /// Stroke width of a tree line.
    static let edgeWidth: CGFloat = 1.5
    /// How far a dependency line bows below the lower of its two nodes.
    static let dependencyBow: CGFloat = 30
    /// Widest note or button group in the tree's top-right corner.
    static let treeDetailMaxWidth: CGFloat = 320
    /// Lines of the op text a hold card shows before "Show all". 10 lines hold about 300 characters at the default node width.
    static let opTextLines = 10
    /// Tallest the scrolled op text of a hold card gets: about 20 lines, so "Show all" opens a box taller than the cut view.
    static let opTextMaxHeight: CGFloat = 300
    /// Rounding room (half a point) when a card stack is checked against the canvas edge and against other stacks.
    static let onScreenSlack: CGFloat = 0.5
    /// Tallest the task list of the Dispatch sheet gets before it scrolls.
    static let taskListMaxHeight: CGFloat = 360
    /// Tallest the rule lists of the /permissions sheet get before they scroll.
    static let ruleListMaxHeight: CGFloat = 320
    /// Tallest the conversation list of the /resume sheet gets before it scrolls.
    static let resumeListMaxHeight: CGFloat = 320
    /// The script output area of the Merge and Teardown sheets: shortest and tallest before it scrolls.
    static let outputMinHeight: CGFloat = 120
    static let outputMaxHeight: CGFloat = 320
    /// The "New project" row at the top of the sidebar is at least this tall, as in v1.
    static let newProjectRowMinHeight: CGFloat = 36
    /// The Settings window content width (mac-design settings.md: a grouped form, 520 wide).
    static let settingsWidth: CGFloat = 520
    /// The accent swatch in Settings.
    static let accentSwatch: CGFloat = 16
    /// The Files popover of the worker actions strip.
    static let filesPopoverWidth: CGFloat = 520
    static let filesPopoverHeight: CGFloat = 280
    /// The Select project popover in the sidebar.
    static let folderPopoverWidth: CGFloat = 240
    static let folderPopoverHeight: CGFloat = 320
    /// The prompt box: one slash-menu row, the tallest the menu and the multi-line field get before they scroll.
    static let menuRow: CGFloat = 24
    static let menuMaxHeight: CGFloat = 192
    static let promptFieldMaxHeight: CGFloat = 120
    /// The go to line field of the editor header.
    static let goToLineWidth: CGFloat = 96
}

/// How much of a fill or a control shows in a state.
enum Fade {
    static let disabled = 0.4
    static let hover = 0.9
    static let pressed = 0.8
    /// Bar content while the window is not the active one.
    static let inactive = 0.6
}

/// The spacing scale of the layout grid.
enum Space {
    /// No gap. The design gate flags a bare number in `spacing:` or a size, so zero has a name too.
    static let none: CGFloat = 0
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum SheetWidth {
    static let small: CGFloat = 360
    static let medium: CGFloat = 480
    static let large: CGFloat = 640
}

/// Type roles. Every role is SF Mono (D-13).
enum KitType: CaseIterable {
    case title, body, label, section, meta

    private var spec: (size: CGFloat, semibold: Bool) {
        switch self {
        case .title: return (13, true)
        case .body: return (13, false)
        case .label: return (12, false)
        case .section: return (12, true)
        case .meta: return (12, false)
        }
    }

    var font: Font {
        .system(size: spec.size, weight: spec.semibold ? .semibold : .regular, design: .monospaced)
    }

    /// The same face for code that measures text (`TreeLayout.titleLines`), so a measure matches what a part draws.
    var nsFont: NSFont {
        .monospacedSystemFont(ofSize: spec.size, weight: spec.semibold ? .semibold : .regular)
    }
}

extension View {
    func kitType(_ role: KitType) -> some View { font(role.font) }
}

/// Motion intents. Every intent except flow resolves to no animation when Reduce Motion is on.
enum Motion: CaseIterable {
    case hover, press, reveal, flow

    /// Tree lines that touch an active node: dash and gap lengths in points, and seconds for the dashes to move one cycle.
    static let flowDash: CGFloat = 4
    static let flowGap: CGFloat = 4
    static let flowPeriod: TimeInterval = 1

    func animation(reduceMotion: Bool) -> Animation? {
        if reduceMotion && self != .flow { return nil }
        switch self {
        case .hover: return .easeOut(duration: 0.12)
        case .press: return .easeOut(duration: 0.08)
        case .reveal: return .easeInOut(duration: 0.2)
        case .flow: return .linear(duration: 1).repeatForever(autoreverses: false)
        }
    }
}

private struct KitAnimation<V: Equatable>: ViewModifier {
    let motion: Motion
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    func kitAnimation<V: Equatable>(_ motion: Motion, value: V) -> some View {
        modifier(KitAnimation(motion: motion, value: value))
    }
}
