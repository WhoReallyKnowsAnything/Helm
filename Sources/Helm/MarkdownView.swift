import Foundation
import Markdown
import SwiftUI

/// The block model of one Markdown text (D-03): the swift-markdown AST reduced to what the kit views draw.
indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
    case quote([MarkdownBlock])
    case code(String)
    case rule
    case table(alignments: [Markdown.Table.ColumnAlignment?], header: [AttributedString], rows: [[AttributedString]])

    /// Parses `text`. Text cut off mid-stream (an open fence, an unclosed `**`) parses like any other text.
    static func parse(_ text: String, linkColor: Color) -> [MarkdownBlock] {
        blocks(of: Document(parsing: text), linkColor)
    }

    private static func blocks(of container: Markup, _ link: Color) -> [MarkdownBlock] {
        container.children.map { child in
            switch child {
            case let heading as Heading: return .heading(level: heading.level, text: inline(heading, link))
            case let paragraph as Paragraph: return .paragraph(inline(paragraph, link))
            case let list as OrderedList:
                return .list(ordered: true, start: Int(list.startIndex), items: list.listItems.map { blocks(of: $0, link) })
            case let list as UnorderedList:
                return .list(ordered: false, start: 1, items: list.listItems.map { blocks(of: $0, link) })
            case let quote as BlockQuote: return .quote(blocks(of: quote, link))
            case let code as CodeBlock:
                return .code(code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code)
            case is ThematicBreak: return .rule
            case let table as Markdown.Table:
                let header: [AttributedString] = table.head.cells.map { inline($0, link) }
                let rows: [[AttributedString]] = table.body.rows.map { row in
                    let cells: [AttributedString] = row.cells.map { inline($0, link) }
                    return fit(cells, to: header.count)
                }
                return .table(alignments: table.columnAlignments, header: header, rows: rows)
            default: return .paragraph(AttributedString(child.format())) // unknown kind: keep its text
            }
        }
    }

    /// The inline children of `markup` as one string. Bold, italic, strike and code are presentation intents,
    /// so the base `kitType` of the view picks the fonts; only links carry a colour.
    static func inline(_ markup: Markup, _ link: Color, _ intent: InlinePresentationIntent = []) -> AttributedString {
        switch markup {
        case let text as Markdown.Text: return styled(text.string, intent)
        case is SoftBreak: return styled(" ", intent)
        case is LineBreak: return styled("\n", intent)
        case let code as InlineCode: return styled(code.code, intent.union(.code))
        case let strong as Strong: return joined(strong, link, intent.union(.stronglyEmphasized))
        case let emphasis as Emphasis: return joined(emphasis, link, intent.union(.emphasized))
        case let strike as Strikethrough: return joined(strike, link, intent.union(.strikethrough))
        case let anchor as Markdown.Link:
            var out = joined(anchor, link, intent)
            if let destination = anchor.destination, let url = URL(string: destination) {
                out.link = url
                out.foregroundColor = link
            }
            return out
        default:
            if markup.childCount > 0 { return joined(markup, link, intent) }
            return styled((markup as? PlainTextConvertibleMarkup)?.plainText ?? markup.format(), intent)
        }
    }

    /// A row padded with empty cells, or cut, to the header width.
    static func fit(_ cells: [AttributedString], to width: Int) -> [AttributedString] {
        Array((cells + Array(repeating: AttributedString(), count: max(0, width - cells.count))).prefix(width))
    }

    private static func joined(_ markup: Markup, _ link: Color, _ intent: InlinePresentationIntent) -> AttributedString {
        markup.children.reduce(into: AttributedString()) { $0.append(inline($1, link, intent)) }
    }

    private static func styled(_ text: String, _ intent: InlinePresentationIntent) -> AttributedString {
        var out = AttributedString(text)
        if !intent.isEmpty { out.inlinePresentationIntent = intent }
        return out
    }
}
