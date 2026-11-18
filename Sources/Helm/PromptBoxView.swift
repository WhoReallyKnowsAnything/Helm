import AppKit
import SwiftUI

/// The conversation's input: the accent `you` gutter label, a multi-line field that grows to a cap and a Send button, with the
/// slash menu above and a failure line. It reports Send and Return through `onSend`; the host clears `text` when `sent` turns true.
/// Look of `KitPromptBar`: `Ink.header` ground, top hairline, content dims while the window is inactive.
struct PromptBoxView: View {
    @Binding var text: String
    let entries: [String]
    let enabled: Bool
    var message: String?
    let onSend: () -> Void
    /// Called on every Esc in the field, turn running or not (D-08). Nil: Esc only closes the slash menu.
    var onEscape: (() -> Void)?
    /// The note set's extra names from init (D-06).
    var terminalCommands: [String] = []
    /// Takes a picked native or note command as `/name`, so Send's rule handles it (D-05).
    var onIntercept: (String) -> Void = { _ in }
    /// True while a question or permission card is shown: the card keeps the keyboard, the field does not claim it.
    var yieldsFocus: Bool = false
    /// Dropped files waiting for Send, shown as removable chips. Empty and no-op defaults: the host opts in.
    var attachments: [URL] = []
    var onAttach: ([URL]) -> Void = { _ in }
    var onDetach: (URL) -> Void = { _ in }
    @State private var dropTargeted = false
    @AppStorage(ConversationFont.familyKey) private var family = ConversationFont.defaultFamily
    @AppStorage(ConversationFont.sizeKey) private var size = ConversationFont.defaultSize
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.kitAccent) private var accent
    @State private var index = 0
    @State private var dismissed = false
    @FocusState private var focused: Bool
    @State private var hostWindow: NSWindow?
    @State private var clickReclaim = ClickReclaim()

    /// The click that activates the app is delivered after `didBecomeActive`, and its mouseDown moves focus to the view under the
    /// pointer. So for a short window after activation, the first mouse up claims focus again. Later clicks are left alone.
    @MainActor final class ClickReclaim {
        static let window: TimeInterval = 1
        private var activatedAt: Date?
        private var monitor: Any?
        func activated(at date: Date = Date()) { activatedAt = date }
        func install(_ claim: @escaping () -> Void) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                if let at = self?.activatedAt, Date().timeIntervalSince(at) < Self.window {
                    self?.activatedAt = nil
                    DispatchQueue.main.async { claim() }
                }
                return event
            }
        }
        func remove() { monitor.map(NSEvent.removeMonitor); monitor = nil }
    }

    private var showsMenu: Bool { enabled && !entries.isEmpty && !dismissed }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if showsMenu { menu }
            if let message {
                Text(message).kitType(.label).foregroundStyle(Ink.textSecondary).textSelection(.enabled)
            }
            if !attachments.isEmpty { chips }
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Text("you").kitType(.section).foregroundStyle(accent.text)
                    .frame(width: Metric.gutter, alignment: .leading)
                TextField("", text: $text, prompt: Text("message this session").foregroundStyle(Ink.muted), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...ConversationFont.promptLines)
                    .conversationFont(.body)
                    .foregroundStyle(Ink.text)
                    .frame(maxHeight: ConversationFont(family: family, size: size).promptFieldMaxHeight)
                    .accessibilityLabel("Message")
                    .focused($focused)
                    .onSubmit(onSend)
                    .onKeyPress(keys: [.upArrow, .downArrow, .tab, .return, .escape]) { handle($0.key) }
                    .onChange(of: entries) { index = 0 }
                    .onChange(of: text) { dismissed = false }
                Button(action: onSend) { KitLabel("Send", icon: .send) }
                    .buttonStyle(.kitPrimary)
            }
        }
        .disabled(!enabled)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { onAttach([url]) } }
                }
            }
            return enabled
        }
        .overlay { if dropTargeted && enabled { Rectangle().stroke(accent.text, lineWidth: 1).allowsHitTesting(false) } }
        .opacity(!enabled ? Fade.disabled : appearsActive ? 1 : Fade.inactive)
        // Left edge matches a row's gutter label: container padding + row padding.
        .padding(.horizontal, Space.lg + Space.md)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The field's max height must cap it, not stretch it into spare space.
        .fixedSize(horizontal: false, vertical: true)
        .background(Ink.header)
        .overlay(alignment: .top) { Ink.border.frame(height: Metric.hairline) }
        .onAppear { claimFocus(); clickReclaim.install { claimFocus() } }
        .onDisappear { clickReclaim.remove() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            clickReclaim.activated()
            claimFocus()
        }
            // The window can become key after didBecomeActive fired, when keyWindow was still unset.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                let became = note.object as? NSWindow
                if Self.mayClaimOnKey(enabled: enabled, yieldsFocus: yieldsFocus, became: became, host: hostWindow) { takeFocus() }
            }
            .background(HostWindow { hostWindow = $0 })
    }

    private func claimFocus() {
        if Self.mayClaim(enabled: enabled, yieldsFocus: yieldsFocus, window: hostWindow ?? NSApp.keyWindow) { takeFocus() }
    }

    /// AppKit selects all text when a field takes focus, so the next key would replace a kept draft: put the caret at the end instead.
    private func takeFocus() {
        // A click can move AppKit focus away while `focused` still reads true, and setting true again would do nothing: drop it first.
        // The pause keeps SwiftUI from merging the false and the true into no change.
        let stale = focused
        if stale { focused = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (stale ? 0.05 : 0)) {
            focused = true
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { Self.placeCaretAtEnd(in: hostWindow ?? NSApp.keyWindow) }
        }
    }

    @MainActor static func placeCaretAtEnd(in window: NSWindow?) {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor, editor.isEditable else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    /// A window that became key claims only for its own box, and the window is the notification's, not `NSApp.keyWindow`.
    @MainActor static func mayClaimOnKey(enabled: Bool, yieldsFocus: Bool, became: NSWindow?, host: NSWindow?) -> Bool {
        guard let became, became === host else { return false }
        return mayClaim(enabled: enabled, yieldsFocus: yieldsFocus, window: became)
    }

    /// No claim over a sheet, a card, or a half-typed message elsewhere.
    @MainActor static func mayClaim(enabled: Bool, yieldsFocus: Bool, window: NSWindow?) -> Bool {
        enabled && !yieldsFocus && window?.attachedSheet == nil && window?.sheetParent == nil && CardKeys.mayClaimFocus(in: window)
    }

    /// The Esc rule, apart from the view so a test fires it without a key event. Never touches the draft.
    static func escape(menuOpen: Bool, onEscape: (() -> Void)?, closeMenu: () -> Void) -> KeyPress.Result {
        if menuOpen { closeMenu() }
        onEscape?()
        return menuOpen || onEscape != nil ? .handled : .ignored
    }

    /// The pick rule, apart from the view so a test fires it without a key event. Nil: the pick went to `intercept`, keep the draft.
    static func pick(_ name: String, terminalCommands: [String], intercept: (String) -> Void) -> String? {
        guard SlashMenu.action(for: "/" + name, terminalCommands: terminalCommands) == .send else { intercept("/" + name); return nil }
        return SlashMenu.pick(name)
    }

    private func choose(_ name: String) {
        if let draft = Self.pick(name, terminalCommands: terminalCommands, intercept: onIntercept) { text = draft }
    }

    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        if key == .escape { return Self.escape(menuOpen: showsMenu, onEscape: onEscape) { dismissed = true } }
        guard showsMenu else { return .ignored }
        switch key {
        case .upArrow: index = SlashMenu.move(index, by: -1, count: entries.count)
        case .downArrow: index = SlashMenu.move(index, by: 1, count: entries.count)
        default:
            guard let name = SlashMenu.highlighted(entries, index: index) else { return .ignored }
            choose(name)
        }
        return .handled
    }

    private var chips: some View {
        HStack(spacing: Space.sm) {
            ForEach(attachments, id: \.self) { url in
                HStack(spacing: Space.xs) {
                    Text(url.lastPathComponent).kitType(.label).foregroundStyle(Ink.text).lineLimit(1).truncationMode(.middle)
                    Button { onDetach(url) } label: { KitImage(.close) }
                        .buttonStyle(.plain).foregroundStyle(Ink.textSecondary)
                        .accessibilityLabel("Remove \(url.lastPathComponent)")
                }
            }
        }
        .padding(.leading, Metric.gutter + Space.md)
    }

    private var menu: some View {
        let height = min(CGFloat(entries.count) * Metric.menuRow, Metric.menuMaxHeight)
        let current = SlashMenu.move(index, by: 0, count: entries.count)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.none) {
                    ForEach(Array(entries.enumerated()), id: \.element) { row, name in
                        Button { choose(name) } label: {
                            Text("/\(name)")
                                .kitType(.body)
                                .foregroundStyle(row == current ? accent.text : Ink.textSecondary)
                                .padding(.horizontal, Space.sm)
                                .frame(maxWidth: .infinity, minHeight: Metric.menuRow, alignment: .leading)
                                .background(row == current ? Ink.border : Color.clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(name)
                    }
                }
            }
            .onChange(of: current) { proxy.scrollTo(entries[current]) }
        }
        .frame(height: height)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.corner))
        .overlay(RoundedRectangle(cornerRadius: Metric.corner).strokeBorder(Ink.border, lineWidth: Metric.hairline))
    }
}

/// Reports the window its view sits in, so the box knows which key-window notification is its own.
struct HostWindow: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reporter(onChange) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Reporter: NSView {
        let onChange: (NSWindow?) -> Void
        init(_ onChange: @escaping (NSWindow?) -> Void) { self.onChange = onChange; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        // The report is delayed, so it runs only while the view still sits in that window: after removal or close the box's state may be gone.
        private(set) var closing = false
        nonisolated(unsafe) private var closeObserver: NSObjectProtocol?
        deinit { closeObserver.map(NotificationCenter.default.removeObserver) }
        override func viewDidMoveToWindow() {
            closeObserver.map(NotificationCenter.default.removeObserver)
            closeObserver = nil
            guard let window else { return }
            closing = false
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closing = true }
            }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, !self.closing, let window, self.window === window else { return }
                self.onChange(window)
            }
        }
    }
}
