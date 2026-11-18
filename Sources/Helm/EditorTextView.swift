import AppKit
import SwiftUI

/// A request to select a line and scroll to it. `token` changes on every press, so the same line twice scrolls twice.
struct EditorScrollRequest: Equatable {
    var line: Int
    var token: Int
}

/// `NSColor(Ink.x)` is a SwiftUI-to-AppKit conversion that costs real time per call; the editor resolves each once.
enum EditorInk {
    static let text = NSColor(Ink.text)
    static let muted = NSColor(Ink.muted)
    static let background = NSColor(Ink.background)
    static let border = NSColor(Ink.border)
    static let keyword = NSColor(Ink.syntaxKeyword)
    static let string = NSColor(Ink.syntaxString)
    static let comment = NSColor(Ink.syntaxComment)
    static let number = NSColor(Ink.syntaxNumber)
    static let key = NSColor(Ink.syntaxKey)
    static let heading = NSColor(Ink.syntaxHeading)

    static func color(for role: SyntaxRole) -> NSColor {
        switch role {
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number: number
        case .key: key
        case .heading: heading
        }
    }
}

/// The file text as a read-only TextKit 1 view with a line number ruler, syntax colours and the system find bar.
struct EditorTextView: NSViewRepresentable {
    let text: String
    let language: SyntaxLanguage
    let request: EditorScrollRequest?
    var isEditable = false
    var onEdit: (String) -> Void = { _ in }
    @AppStorage(ConversationFont.familyKey) private var family = ConversationFont.defaultFamily
    @AppStorage(ConversationFont.sizeKey) private var size = ConversationFont.defaultSize

    private var font: ConversationFont { ConversationFont(family: family, size: size) }

    static func makeScrollView() -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = Metric.hairline
        layout.addTextContainer(container)
        let textView = EditorNSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: Space.sm, height: Space.sm)
        textView.font = KitType.body.nsFont
        textView.usesFindBar = true
        // Source code must stay exact: plain text, no automatic changes.
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isIncrementalSearchingEnabled = true
        let scroll = EditorScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = textView
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll)
        scroll.rulersVisible = true
        return scroll
    }

    /// Replaces the text and colours it with the tokenizer.
    static func setText(_ text: String, language: SyntaxLanguage, font setting: ConversationFont = .default, in scroll: NSScrollView) {
        guard let textView = scroll.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let font = setting.nsFont(for: .body)
        textView.typingAttributes[.font] = font
        (scroll.verticalRulerView as? LineNumberRuler)?.font = setting
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: EditorInk.text]))
        for token in SyntaxTokenizer.tokenize(text, language: language) {
            storage.addAttribute(.foregroundColor, value: EditorInk.color(for: token.role), range: token.range)
        }
        storage.endEditing()
        // A text set by the program starts a fresh undo history.
        textView.undoManager?.removeAllActions()
        (scroll.verticalRulerView as? LineNumberRuler)?.setText(text)
    }

    /// Sets the font of the shown text in place. Attributes only, so the selection, the scroll position and the undo stack survive.
    static func restyle(font setting: ConversationFont, in scroll: NSScrollView) {
        guard let textView = scroll.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let font = setting.nsFont(for: .body)
        storage.beginEditing()
        storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.typingAttributes[.font] = font
        (scroll.verticalRulerView as? LineNumberRuler)?.font = setting
    }

    /// Colours the current text again after a user edit. Attributes only, so the selection and the undo stack survive.
    static func recolour(_ textView: NSTextView, language: SyntaxLanguage) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: EditorInk.text, range: NSRange(location: 0, length: storage.length))
        for token in SyntaxTokenizer.tokenize(text, language: language) {
            storage.addAttribute(.foregroundColor, value: EditorInk.color(for: token.role), range: token.range)
        }
        storage.endEditing()
        (textView.enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.setText(text)
    }

    /// Selects the 1-based `line` and scrolls to it. False for a value that is not a line of the text.
    @discardableResult
    static func select(line: Int, in scroll: NSScrollView) -> Bool {
        guard let textView = scroll.documentView as? NSTextView,
              let range = EditorText.lineRange(line, in: textView.string) else { return false }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        return true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: String?
        var language: SyntaxLanguage?
        var font: ConversationFont?
        var onEdit: (String) -> Void = { _ in }

        /// Called for user edits only: a text set by the program goes through `setText` and does not reach here.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let edited = textView.string
            text = edited
            if let language { EditorTextView.recolour(textView, language: language) }
            onEdit(edited)
        }
        var token: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView()
        (scroll.documentView as? NSTextView)?.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onEdit = onEdit
        (scroll.documentView as? NSTextView)?.isEditable = isEditable
        if c.text != text || c.language != language {
            Self.setText(text, language: language, font: font, in: scroll)
            c.text = text
            c.language = language
            c.font = font
        } else if c.font != font {
            Self.restyle(font: font, in: scroll)
            c.font = font
        }
        if let request, request.token != c.token {
            c.token = request.token
            Self.select(line: request.line, in: scroll)
        }
    }
}

/// A new clip view starts at x 0, under the ruler. The first tile that sets the ruler inset moves it to the true left edge, once.
final class EditorScrollView: NSScrollView {
    private var placed = false

    override func tile() {
        super.tile()
        let inset = contentView.contentInsets.left
        guard !placed, inset > 0 else { return }
        placed = true
        contentView.scroll(to: NSPoint(x: -inset, y: contentView.bounds.origin.y))
        reflectScrolledClipView(contentView)
    }
}

/// Cmd-F shows the find bar even when the app menu has no Find item.
final class EditorNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f", window?.firstResponder === self {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            performTextFinderAction(item)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Line numbers of the visible lines, in the muted colour and the editor font. Lines do not wrap, so each fragment is one line.
final class LineNumberRuler: NSRulerView {
    private var lineStarts = [0]
    var font = ConversationFont.default {
        didSet {
            ruleThickness = thickness(digits: String(lineStarts.count).count)
            needsDisplay = true
        }
    }

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = scrollView.documentView
        ruleThickness = thickness(digits: 1)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func setText(_ text: String) {
        var starts = [0]
        var index = 0
        for unit in text.utf16 {
            index += 1
            if unit == 10 { starts.append(index) }
        }
        lineStarts = starts
        ruleThickness = thickness(digits: String(starts.count).count)
        needsDisplay = true
    }

    private func thickness(digits: Int) -> CGFloat {
        let digit = ("8" as NSString).size(withAttributes: [.font: font.nsFont(for: .body)]).width
        return ceil(digit * CGFloat(max(digits, 2))) + Space.sm * 2
    }

    /// The 1-based line that starts at `index`, or nil when `index` is not a line start.
    private func line(startingAt index: Int) -> Int? {
        var low = 0, high = lineStarts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] == index { return mid + 1 }
            if lineStarts[mid] < index { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    // Not super: the system draw paints the appearance's light ruler background.
    override func draw(_ dirtyRect: NSRect) {
        EditorInk.background.setFill()
        bounds.fill()
        EditorInk.border.setFill()
        NSRect(x: bounds.maxX - Metric.hairline, y: bounds.minY, width: Metric.hairline, height: bounds.height).fill()
        drawHashMarksAndLabels(in: bounds)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font.nsFont(for: .body), .foregroundColor: EditorInk.muted]
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let origin = textView.textContainerOrigin
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let char = layout.characterIndexForGlyph(at: glyphRange.location)
            guard let number = self.line(startingAt: char) else { return }
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            let y = self.convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            label.draw(at: NSPoint(x: self.ruleThickness - Space.sm - size.width, y: y), withAttributes: attributes)
        }
    }
}
