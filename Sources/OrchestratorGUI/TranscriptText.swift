import AppKit
import Markdown
import SwiftUI

/// The whole conversation as one attributed string, so one TextKit 1 text view can select and copy across messages.
/// Rows are text blocks: each row's paragraphs share one `RoundedTextBlock`, which draws the row fill.
enum TranscriptText {
    static let toolScheme = "orchestrator-tool"
    /// The content column: the label gutter plus the column gap.
    static let gutter = Metric.gutter + Space.md
    static let listIndent = Space.xl + Space.sm

    @MainActor
    static func build(_ items: [ConversationItem], accent: AccentSwatch, expanded: Set<String>, font: ConversationFont = .default) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let fonts = FontTable.shared(for: font)
        for (index, row) in ConversationView.displayRows(items).enumerated() { out.append(buildRow(row, index: index, accent: accent, expanded: expanded, fonts: fonts)) }
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// One row with its trailing "\n". Only the row's items and whether it is row 0 change what it looks like.
    static func buildRow(_ row: ConversationView.DisplayRow, index: Int, accent: AccentSwatch, expanded: Set<String>,
                         fonts: FontTable) -> NSAttributedString {
        var builder = Builder(accent: NSColor(accent.text), linkColor: accent.text, expanded: expanded, fonts: fonts)
        builder.row(row, index: index)
        return builder.out
    }

    static let runScheme = "orchestrator-run"

    /// The expanded-set key of a tool run. A run's id is its first call's id, so the run key needs its own prefix.
    static func runKey(_ id: String) -> String { "run:" + id }

    /// What each tool line's glyph means, for VoiceOver.
    static let stateNames: [Character: String] = ["›": "running", "✓": "done", "✗": "failed"]

    /// The tool lines of a built transcript, for VoiceOver: the link range, the text after the glyph,
    /// and "<state>, expanded" or "<state>, collapsed".
    static func toolAccessibility(_ text: NSAttributedString, expanded: Set<String>)
        -> [(range: NSRange, url: URL, label: String, value: String)] {
        var lines: [(range: NSRange, url: URL, label: String, value: String)] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { link, range, _ in
            guard let url = link as? URL, let key = expandedKey(url) else { return }
            let line = (text.string as NSString).substring(with: range).trimmingCharacters(in: .newlines)
            guard let glyph = line.first else { return }
            let state = stateNames[glyph] ?? ""
            lines.append((NSRange(location: range.location, length: (line as NSString).length), url,
                          String(line.dropFirst(2)), state + ", " + (expanded.contains(key) ? "expanded" : "collapsed")))
        }
        return lines
    }

    static func link(_ scheme: String, _ id: String) -> URL? {
        URL(string: scheme + ":" + (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
    }

    /// The expanded-set key a link toggles: the call id for a tool line, the run key for a run line, nil for other links.
    static func expandedKey(_ url: URL) -> String? {
        guard let scheme = url.scheme, scheme == toolScheme || scheme == runScheme,
              let id = String(url.absoluteString.dropFirst(scheme.count + 1)).removingPercentEncoding else { return nil }
        return scheme == runScheme ? runKey(id) : id
    }

    /// Parsing one message costs about 0.4 ms, so a session that is opened again, or a row that is rebuilt, reuses it.
    /// A message still streaming changes with every delta and is never kept. Rows build on several threads, hence the lock.
    private enum ParseCache {
        private struct Key: Hashable { let text: String, link: Color }
        nonisolated(unsafe) private static var store: [Key: [MarkdownBlock]] = [:]
        private static let lock = NSLock()

        static func reset() {
            lock.lock()
            store.removeAll()
            lock.unlock()
        }

        static func blocks(_ text: String, _ link: Color, cache: Bool) -> [MarkdownBlock] {
            let key = Key(text: text, link: link)
            if cache {
                lock.lock()
                let hit = store[key]
                lock.unlock()
                if let hit { return hit }
            }
            let parsed = MarkdownBlock.parse(text, linkColor: link)
            if cache {
                lock.lock()
                if store.count >= 1000 { store.removeAll() }
                store[key] = parsed
                lock.unlock()
            }
            return parsed
        }
    }

    /// Parsing is the one part of a build that speeds up on several cores (the rest fights over shared AppKit objects),
    /// so a long run of new messages parses in parallel first and the serial build then finds every parse in the cache.
    static func parseInParallel(_ rows: [ConversationView.DisplayRow], link: Color) {
        let texts = rows.compactMap { row -> String? in
            if case .single(.assistant(_, let text, false)) = row { return text }
            return nil
        }
        guard texts.count > 1 else { return }
        DispatchQueue.concurrentPerform(iterations: texts.count) { _ = ParseCache.blocks(texts[$0], link, cache: true) }
    }

    /// Forgets every parsed message, so a test can measure a first open.
    static func resetParseCache() { ParseCache.reset() }

    /// Where a paragraph goes: its blocks (outer first), the head indent inside the innermost block and the text colour.
    private struct Scope {
        var blocks: [NSTextBlock]
        var indent: CGFloat
        var colour: NSColor
    }

    private struct Builder {
        let accent: NSColor
        let linkColor: Color
        let expanded: Set<String>
        let fonts: FontTable
        let out = NSMutableAttributedString()
        /// The row label (with its tab), put in front of the row's first paragraph.
        var label: NSAttributedString?

        mutating func row(_ row: ConversationView.DisplayRow, index: Int) {
            let block = RoundedTextBlock()
            // A block with no width shrinks to its widest glyph in some layouts, so every block takes the full width.
            block.setValue(100, type: .percentageValueType, for: .width)
            var top = index > 0 ? Space.xs : Space.none
            block.setWidth(Space.md, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(Space.md, type: .absoluteValueType, for: .padding, edge: .maxX)
            let scope = Scope(blocks: [block], indent: TranscriptText.gutter, colour: NSInk.text)
            switch row {
            case .tools(let id, let tools):
                self.tools(id, tools, block, scope)
            case .single(let item):
                switch item {
                case .user(_, let text):
                    if index > 0 { top += Space.sm }
                    block.fill = NSInk.youRowFill
                    block.stroke = NSInk.border
                    vertical(block, Space.sm)
                    label = styled("you\t", .section, accent)
                    emit(styled(text, .body, NSInk.text), scope)
                case .assistant(_, let text, let inProgress):
                    block.fill = NSInk.claudeRowFill
                    vertical(block, Space.sm)
                    label = styled("claude\t", .section, NSInk.textSecondary)
                    markdown(ParseCache.blocks(text, linkColor, cache: !inProgress), scope, leading: Space.none)
                    if label != nil { emit(NSAttributedString(), scope) }
                case .tool:
                    self.tools(item.id, [item], block, scope)
                case .status(_, let text):
                    var plain = scope
                    plain.indent = Space.none
                    emit(styled(ConversationView.statusDisplay(text), .meta, NSInk.muted), plain)
                }
            }
            block.setWidth(top, type: .absoluteValueType, for: .margin, edge: .minY)
        }

        private func vertical(_ block: NSTextBlock, _ inset: CGFloat) {
            block.setWidth(inset, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(inset, type: .absoluteValueType, for: .padding, edge: .maxY)
        }

        /// A run is one collapsed line (`lean-ctx ×10 · Bash ×2`), a link that toggles the run's key.
        /// Expanded, the per-call lines follow it.
        private mutating func tools(_ id: String, _ tools: [ConversationItem], _ block: NSTextBlock, _ scope: Scope) {
            vertical(block, Metric.toolsInset)
            label = styled("tools\t", .meta, NSInk.muted)
            var failed = false, running = false
            for case .tool(_, _, _, let result) in tools {
                if let result { failed = failed || result.isError } else { running = true }
            }
            let glyph: (String, NSColor) = failed ? ("✗", NSInk.toolFailed) : running ? ("›", accent) : ("✓", NSInk.toolDone)
            let line = NSMutableAttributedString(attributedString: styled(glyph.0 + " ", .label, glyph.1))
            let summary = ConversationView.toolGroups(tools).map { "\($0.key) ×\($0.count)" }.joined(separator: " · ")
            line.append(styled(summary, .label, NSInk.textSecondary))
            if let url = TranscriptText.link(TranscriptText.runScheme, id) {
                line.addAttribute(.link, value: url, range: NSRange(location: 0, length: line.length))
            }
            emit(line, scope)
            guard expanded.contains(TranscriptText.runKey(id)) else { return }
            for tool in tools { self.tool(tool, scope, before: Metric.toolLineGap) }
        }

        /// The tool line is one link (`orchestrator-tool:<id>`); a click toggles its id in the expanded set.
        private mutating func tool(_ item: ConversationItem, _ scope: Scope, before: CGFloat) {
            guard case .tool(let id, let name, let input, let result) = item else { return }
            let secondary = NSInk.textSecondary, muted = NSInk.muted
            let glyph: (String, NSColor) = result.map { $0.isError ? ("✗", NSInk.toolFailed) : ("✓", NSInk.toolDone) } ?? ("›", accent)
            let line = NSMutableAttributedString(attributedString: styled(glyph.0 + " ", .label, glyph.1))
            line.append(styled([name, toolSummary(input)].filter { !$0.isEmpty }.joined(separator: " "), .label, secondary))
            if let url = TranscriptText.link(TranscriptText.toolScheme, id) { line.addAttribute(.link, value: url, range: NSRange(location: 0, length: line.length)) }
            emit(line, scope, before: before)
            guard expanded.contains(id) else { return }
            var detail = scope
            detail.indent += Space.lg
            if let blocks = lineDiff(tool: name, input: input) {
                for block in blocks {
                    if let path = block.path { emit(styled(path, .section, secondary), detail, before: Space.xs) }
                    for diff in block.lines {
                        let marker: String, fill: NSColor?, colour: NSColor
                        switch diff.kind {
                        case .added: (marker, fill, colour) = ("+", NSInk.diffAddedFill, NSInk.diffAddedText)
                        case .removed: (marker, fill, colour) = ("-", NSInk.diffRemovedFill, NSInk.diffRemovedText)
                        case .unchanged: (marker, fill, colour) = (" ", nil, secondary)
                        }
                        let text = styled(marker + " " + diff.text, .label, colour)
                        if let fill {
                            let band = NSTextBlock()
                            band.backgroundColor = fill
                            emit(text, nest(band, detail, 0))
                        } else {
                            emit(text, detail)
                        }
                    }
                }
            } else {
                emit(styled(formattedInput(input), .label, secondary), detail, before: Space.xs)
            }
            guard let result else { return emit(styled("no result yet", .meta, muted), detail, before: Space.xs) }
            if result.isError {
                let label = NSMutableAttributedString()
                let config = NSImage.SymbolConfiguration(pointSize: KitIcon.size, weight: .regular)
                    .applying(.init(paletteColors: [NSInk.text]))
                if let icon = NSImage(systemSymbolName: KitIcon.warning.rawValue, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let attachment = NSTextAttachment()
                    attachment.image = icon
                    label.append(NSAttributedString(attachment: attachment))
                    label.append(styled(" ", .section, NSInk.text))
                }
                label.append(styled("error", .section, NSInk.text))
                emit(label, detail, before: Space.xs)
            }
            emit(styled(String(result.text.prefix(toolResultCap)), .label, secondary), detail, before: Space.xs)
            if result.text.count > toolResultCap {
                emit(styled("\(result.text.count - toolResultCap) more characters cut", .meta, muted), detail, before: Space.xs)
            }
        }

        private mutating func markdown(_ blocks: [MarkdownBlock], _ scope: Scope, leading: CGFloat) {
            for (i, block) in blocks.enumerated() { markdown(block, scope, before: i == 0 ? leading : Space.sm) }
        }

        private mutating func markdown(_ block: MarkdownBlock, _ scope: Scope, before: CGFloat) {
            switch block {
            case .heading(let level, let text):
                emit(inline(text, level <= 2 ? .title : .section, scope.colour), scope, before: before)
            case .paragraph(let text):
                emit(inline(text, .body, scope.colour), scope, before: before)
            case .list(let ordered, let start, let items):
                var inner = scope
                inner.indent += TranscriptText.listIndent
                for (i, item) in items.enumerated() {
                    let line = NSMutableAttributedString(attributedString: styled(ordered ? "\t\(start + i).\t" : "\t•\t", .body, NSInk.muted))
                    var rest = item[...]
                    if case .paragraph(let text)? = item.first {
                        line.append(inline(text, .body, scope.colour))
                        rest = item.dropFirst()
                    }
                    emit(line, inner, first: scope.indent, tabs: [NSTextTab(textAlignment: .right, location: scope.indent + Space.xl), NSTextTab(textAlignment: .left, location: inner.indent)], before: i == 0 ? before : Space.xs)
                    markdown(Array(rest), inner, leading: Space.sm)
                }
            case .quote(let blocks):
                let quote = NSTextBlock()
                quote.setWidth(Metric.selectedEdge, type: .absoluteValueType, for: .border, edge: .minX)
                quote.setBorderColor(NSInk.borderStrong, for: .minX)
                quote.setWidth(Space.sm, type: .absoluteValueType, for: .padding, edge: .minX)
                var inner = nest(quote, scope, before)
                inner.colour = NSInk.textSecondary
                markdown(blocks, inner, leading: Space.none)
            case .code(let code):
                let box = RoundedTextBlock()
                box.fill = NSInk.codeFill
                box.setWidth(Space.sm, type: .absoluteValueType, for: .padding)
                emit(styled(code, .label, NSInk.text), nest(box, scope, before))
            case .rule:
                let rule = NSTextBlock()
                rule.setWidth(Metric.hairline, type: .absoluteValueType, for: .border, edge: .maxY)
                rule.setBorderColor(NSInk.border, for: .maxY)
                emit(NSAttributedString(), nest(rule, scope, before))
            case .table(let alignments, let header, let rows):
                guard !header.isEmpty else { return }
                let table = NSTextTable()
                table.numberOfColumns = header.count
                _ = nest(table, scope, before)
                let all = [header] + rows
                for (r, cells) in all.enumerated() {
                    for (c, cell) in cells.enumerated() {
                        let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                        block.setWidth(Space.lg / 2, type: .absoluteValueType, for: .padding)
                        if r < all.count - 1 {
                            block.setWidth(Metric.hairline, type: .absoluteValueType, for: .border, edge: .maxY)
                            block.setBorderColor(NSInk.border, for: .maxY)
                        }
                        let align: NSTextAlignment = switch c < alignments.count ? alignments[c] : nil {
                        case .center?: .center
                        case .right?: .right
                        default: .left
                        }
                        emit(inline(cell, r == 0 ? .section : .body, scope.colour),
                             Scope(blocks: scope.blocks + [block], indent: Space.none, colour: scope.colour), align: align)
                    }
                }
            }
        }

        /// A block inside the current one: it starts at the current indent, `before` below the last paragraph.
        private func nest(_ block: NSTextBlock, _ scope: Scope, _ before: CGFloat) -> Scope {
            block.setValue(100, type: .percentageValueType, for: .width)
            block.setWidth(scope.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            block.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
            return Scope(blocks: scope.blocks + [block], indent: Space.none, colour: scope.colour)
        }

        /// Appends `text` as paragraphs. The first line starts at `first` (the head indent by default); later lines
        /// hang at the head indent. A pending row label goes in front, on its own line when the scope is a nested block.
        private mutating func emit(_ text: NSAttributedString, _ scope: Scope, first: CGFloat? = nil, tabs: [NSTextTab] = [],
                                   before: CGFloat = Space.none, align: NSTextAlignment = .natural) {
            if label != nil, scope.blocks.count > 1 {
                emit(NSAttributedString(), Scope(blocks: [scope.blocks[0]], indent: TranscriptText.gutter, colour: scope.colour))
            }
            let line = NSMutableAttributedString()
            var firstIndent = first ?? scope.indent
            if let label {
                line.append(label)
                firstIndent = Space.none
                self.label = nil
            }
            line.append(text)
            let end: [NSAttributedString.Key: Any] = line.length > 0 ? line.attributes(at: line.length - 1, effectiveRange: nil) : [.font: fontFor(.meta)]
            line.append(NSAttributedString(string: "\n", attributes: end))

            let rest = NSMutableParagraphStyle()
            rest.textBlocks = scope.blocks
            rest.headIndent = scope.indent
            rest.firstLineHeadIndent = scope.indent
            rest.alignment = align
            // TextKit 1 drops the block layout of a line whose fonts differ in height, so every line gets the tallest height.
            var tallest: CGFloat = 0
            line.enumerateAttribute(.font, in: NSRange(location: 0, length: line.length)) { font, _, _ in
                if let font = font as? NSFont { tallest = max(tallest, lineHeight(font)) }
            }
            rest.minimumLineHeight = tallest
            rest.tabStops = ([NSTextTab(textAlignment: .left, location: TranscriptText.gutter)] + tabs).sorted { $0.location < $1.location }
            let head = rest.mutableCopy() as! NSMutableParagraphStyle
            head.firstLineHeadIndent = firstIndent
            head.paragraphSpacingBefore = before

            let firstLength = (line.string as NSString).range(of: "\n").location + 1
            line.addAttribute(.paragraphStyle, value: head, range: NSRange(location: 0, length: firstLength))
            if firstLength < line.length {
                line.addAttribute(.paragraphStyle, value: rest, range: NSRange(location: firstLength, length: line.length - firstLength))
            }
            out.append(line)
        }

        private func inline(_ text: AttributedString, _ type: KitType, _ colour: NSColor) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for run in text.runs {
                let intent = run.inlinePresentationIntent ?? []
                let font = fontFor(type, strong: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized))
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link {
                    attributes[.link] = link
                    attributes[.foregroundColor] = accent
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
            }
            return out
        }

        private func fontFor(_ type: KitType, strong: Bool = false, italic: Bool = false) -> NSFont {
            fonts.font(type, strong: strong, italic: italic)
        }

        private func lineHeight(_ font: NSFont) -> CGFloat { fonts.heights[font] ?? 0 }

        private func styled(_ string: String, _ type: KitType, _ colour: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: fontFor(type), .foregroundColor: colour])
        }
    }
}

/// Building a font and asking for its line height both cost real time per run, and both are AppKit calls for the main thread.
/// Every font a row can use is built once per setting on the main actor. The table is a value nothing writes to afterwards,
/// so a build on any thread only reads it.
struct FontTable: @unchecked Sendable {
    private struct Key: Hashable { let type: KitType, strong: Bool, italic: Bool }

    @MainActor private static var latest: (setting: ConversationFont, table: FontTable)?

    private let fonts: [Key: NSFont]
    let heights: [NSFont: CGFloat]

    @MainActor private init(_ setting: ConversationFont) {
        var table: [Key: NSFont] = [:]
        for type in KitType.allCases {
            for strong in [false, true] { for italic in [false, true] {
                table[Key(type: type, strong: strong, italic: italic)] = setting.nsFont(for: type, strong: strong, italic: italic)
            } }
        }
        fonts = table
        let layout = NSLayoutManager()
        heights = Dictionary(table.values.map { ($0, layout.defaultLineHeight(for: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// The table of the latest setting. A new setting builds a new table; a build in flight keeps the one it holds.
    @MainActor static func shared(for setting: ConversationFont) -> FontTable {
        if let latest, latest.setting == setting { return latest.table }
        let table = FontTable(setting)
        latest = (setting, table)
        return table
    }

    func font(_ type: KitType, strong: Bool, italic: Bool) -> NSFont { fonts[Key(type: type, strong: strong, italic: italic)]! }
}

/// A text block that draws one rounded rect inside its margins: the fill, then an optional hairline border.
/// The border is drawn, not laid out, like the SwiftUI `strokeBorder` it replaces.
final class RoundedTextBlock: NSTextBlock {
    var fill: NSColor?
    var stroke: NSColor?

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        (copy as? RoundedTextBlock)?.fill = fill
        (copy as? RoundedTextBlock)?.stroke = stroke
        return copy
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        let left = width(for: .margin, edge: .minX), top = width(for: .margin, edge: .minY)
        let rect = NSRect(x: frameRect.minX + left, y: frameRect.minY + top,
                          width: frameRect.width - left - width(for: .margin, edge: .maxX),
                          height: frameRect.height - top - width(for: .margin, edge: .maxY))
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: Metric.corner, yRadius: Metric.corner).fill()
        }
        if let stroke {
            let inset = Metric.hairline / 2
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: Metric.corner, yRadius: Metric.corner)
            path.lineWidth = Metric.hairline
            stroke.setStroke()
            path.stroke()
        }
    }
}

/// The transcript text view. VoiceOver gets one button per tool line, with its state and whether it is expanded.
final class TranscriptNSTextView: NSTextView {
    /// The expanded set the shown text was built with.
    var expanded: Set<String> = []

    /// A tool line for VoiceOver: pressing it clicks its link, like a mouse click.
    final class ToolLineElement: NSAccessibilityElement {
        var press: () -> Void = {}
        override func accessibilityPerformPress() -> Bool { press(); return true }
    }

    override func accessibilityChildren() -> [Any]? {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return super.accessibilityChildren() }
        let origin = textContainerOrigin
        let lines = TranscriptText.toolAccessibility(storage, expanded: expanded).map { line in
            let element = ToolLineElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(line.label)
            element.setAccessibilityValue(line.value)
            element.setAccessibilityParent(self)
            let glyphs = layout.glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            element.setAccessibilityFrame(NSAccessibility.screenRect(fromView: self, rect: rect))
            element.press = { [weak self] in
                guard let self else { return }
                _ = delegate?.textView?(self, clickedOnLink: line.url, at: line.range.location)
            }
            return element
        }
        return (super.accessibilityChildren() ?? []) + lines
    }
}

/// The scroll view of the transcript. It stays at the bottom when it was there before a change or a resize.
final class TranscriptScrollView: NSScrollView {
    /// True until the first scroll to the bottom with a real height, so the first load pins like a view at the bottom.
    var stuck = true

    var atBottom: Bool {
        guard let document = documentView else { return true }
        return contentView.bounds.maxY >= document.frame.maxY - 1
    }

    func scrollToBottom() {
        guard let textView = documentView as? NSTextView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        textView.sizeToFit()
        contentView.scroll(to: NSPoint(x: 0, y: max(0, textView.frame.height - contentView.bounds.height)))
        reflectScrolledClipView(contentView)
        if contentView.bounds.height > 0 { stuck = false }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let pin = stuck || atBottom
        super.setFrameSize(newSize)
        if pin { scrollToBottom() }
    }
}

/// The conversation as one read-only TextKit 1 text view (TextKit 2 drops text blocks and tables).
/// A drag selects across messages, auto-scrolls at the edge, and Cmd-C copies the selection in order.
struct TranscriptTextView: NSViewRepresentable {
    let items: [ConversationItem]
    let accent: AccentSwatch
    let expanded: Set<String>
    var font = ConversationFont.default
    let onToggle: (String) -> Void

    static func makeScrollView() -> TranscriptScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // SwiftUI `Text` draws 1 pt in from its frame; the same inset keeps the labels on the prompt box edge.
        container.lineFragmentPadding = Metric.hairline
        layout.addTextContainer(container)
        let textView = TranscriptNSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: Space.lg, height: Space.lg)
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        let scroll = TranscriptScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = textView
        return scroll
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptScrollView {
        let scroll = Self.makeScrollView()
        (scroll.documentView as? NSTextView)?.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: TranscriptScrollView, context: Context) {
        context.coordinator.onToggle = onToggle
        Self.render(scroll, coordinator: context.coordinator, items: items, accent: accent, expanded: expanded, font: font)
    }

    static func render(_ scroll: TranscriptScrollView, coordinator: Coordinator, items: [ConversationItem], accent: AccentSwatch, expanded: Set<String>,
                       font: ConversationFont = .default) {
        let key = Coordinator.Key(items: items, expanded: expanded, accent: accent.text, font: font)
        let fonts = FontTable.shared(for: font)
        guard key != coordinator.key, let textView = scroll.documentView as? TranscriptNSTextView, let storage = textView.textStorage else { return }
        let restyled = coordinator.key.map { $0.expanded != expanded || $0.accent != accent.text || $0.font != font } ?? true
        coordinator.key = key
        textView.expanded = expanded
        let pin = scroll.stuck || scroll.atBottom
        let selection = textView.selectedRange()
        let old = restyled ? [] : coordinator.rows
        let inputs = ConversationView.displayRows(items).enumerated().map { index, row -> (row: ConversationView.DisplayRow, input: Coordinator.RowInput) in
            switch row {
            case .single(let item): return (row, .init(items: [item], isFirst: index == 0))
            case .tools(_, let run): return (row, .init(items: run, isFirst: index == 0))
            }
        }
        var first = zip(inputs, old).prefix { $0.input == $1.input }.count
        // The old last row's trailing "\n" was trimmed from the storage, so a changed tail starts one row earlier.
        if first == old.count || first == inputs.count { first = max(first - 1, 0) }
        let start = old.prefix(first).reduce(0) { $0 + $1.text.length }
        var rows = Array(old.prefix(first))
        let tail = NSMutableAttributedString()
        let reused = { (index: Int) in index < old.count && old[index].input == inputs[index].input }
        TranscriptText.parseInParallel((first..<inputs.count).filter { !reused($0) }.map { inputs[$0].row }, link: accent.text)
        for index in first..<inputs.count {
            let input = inputs[index].input
            let text = reused(index)
                ? old[index].text : TranscriptText.buildRow(inputs[index].row, index: index, accent: accent, expanded: expanded, fonts: fonts)
            rows.append(.init(input: input, text: text))
            tail.append(text)
        }
        if tail.string.hasSuffix("\n") { tail.deleteCharacters(in: NSRange(location: tail.length - 1, length: 1)) }
        coordinator.rows = rows
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
        storage.endEditing()
        let location = min(selection.location, storage.length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, storage.length - location)))
        if pin { scroll.scrollToBottom() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// The inputs of the shown text. The built string cannot be compared: its text blocks are new objects each build.
        struct Key: Equatable {
            let items: [ConversationItem]
            let expanded: Set<String>
            let accent: Color
            let font: ConversationFont
        }

        /// What a built row depends on besides accent and expanded.
        struct RowInput: Equatable {
            let items: [ConversationItem]
            let isFirst: Bool
        }

        struct Row {
            let input: RowInput
            let text: NSAttributedString
        }

        var key: Key?
        var rows: [Row] = []
        var onToggle: (String) -> Void = { _ in }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, let id = TranscriptText.expandedKey(url) else { return false }
            onToggle(id)
            return true
        }
    }
}

/// `NSColor(Ink.x)` is a SwiftUI-to-AppKit conversion that costs real time per call; the transcript builder resolves each once.
private enum NSInk {
    static let text = NSColor(Ink.text)
    static let youRowFill = NSColor(Ink.youRowFill)
    static let border = NSColor(Ink.border)
    static let claudeRowFill = NSColor(Ink.claudeRowFill)
    static let textSecondary = NSColor(Ink.textSecondary)
    static let muted = NSColor(Ink.muted)
    static let toolFailed = NSColor(Ink.toolFailed)
    static let toolDone = NSColor(Ink.toolDone)
    static let diffAddedFill = NSColor(Ink.diffAddedFill)
    static let diffAddedText = NSColor(Ink.diffAddedText)
    static let diffRemovedFill = NSColor(Ink.diffRemovedFill)
    static let diffRemovedText = NSColor(Ink.diffRemovedText)
    static let borderStrong = NSColor(Ink.borderStrong)
    static let codeFill = NSColor(Ink.codeFill)
}
