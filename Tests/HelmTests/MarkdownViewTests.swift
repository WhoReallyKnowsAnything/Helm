import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Helm

@MainActor
struct MarkdownViewTests {
    private func parse(_ text: String) -> [MarkdownBlock] { MarkdownBlock.parse(text, linkColor: .red) }

    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    @Test func aHeadingGivesAHeadingBlock() throws {
        guard case .heading(let level, let text)? = parse("## Title").first else { Issue.record("no heading"); return }
        #expect(level == 2)
        #expect(plain(text) == "Title")
    }

    @Test func aNestedListKeepsItsChildList() throws {
        guard case .list(let ordered, _, let items)? = parse("- a\n  - b\n- c").first else { Issue.record("no list"); return }
        #expect(!ordered)
        #expect(items.count == 2)
        #expect(items[0].contains { if case .list = $0 { return true } else { return false } })
    }

    @Test func aNumberedListKeepsItsStart() throws {
        guard case .list(let ordered, let start, _)? = parse("3. x\n4. y").first else { Issue.record("no list"); return }
        #expect(ordered)
        #expect(start == 3)
    }

    @Test func aFencedBlockAndAQuoteGiveTheirBlocks() throws {
        #expect(parse("```\nlet x = 1\n```") == [.code("let x = 1")])
        guard case .quote(let inner)? = parse("> said").first else { Issue.record("no quote"); return }
        #expect(inner.count == 1)
    }

    @Test func inlineMarksBecomePresentationIntents() throws {
        guard case .paragraph(let text)? = parse("**bold** and *italic* and `code` and [l](https://x.test)").first else {
            Issue.record("no paragraph"); return
        }
        let intents = text.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.emphasized))
        #expect(intents.contains(.code))
        #expect(text.runs.contains { $0.link == URL(string: "https://x.test") })
    }

    @Test func cutOffTextStillParsesAndRenders() throws {
        #expect(!parse("intro\n```swift\nlet x").isEmpty)
        #expect(!parse("**x").isEmpty)
        for text in ["intro\n```swift\nlet x", "**x"] {
            let rep = try RenderSupport.render(ConversationView(items: [.assistant(id: "a", text: text, inProgress: false)]), .fixed(CGSize(width: 300, height: 200)))
            #expect(rep.pixelsHigh > 0)
        }
    }

    @Test func longCodeAndWideTablesWrapInsteadOfScrolling() {
        let token = String(repeating: "x", count: 200)
        let pairs = [
            ("```\n\(token)\n```", "```\nx\n```"),
            ("| a | b |\n|---|---|\n| \(token) | one two three four five six seven eight nine ten |", "| a | b |\n|---|---|\n| x | y |"),
        ]
        // The transcript text view at 300 pt: the used text height, and no sideways scroller.
        func height(_ text: String) -> CGFloat {
            let scroll = TranscriptTextView.makeScrollView()
            scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
            guard let textView = scroll.documentView as? NSTextView, let layout = textView.layoutManager,
                  let container = textView.textContainer else { return 0 }
            textView.textStorage?.setAttributedString(
                TranscriptText.build([.assistant(id: "a", text: text, inProgress: false)], accent: Ink.accent, expanded: []))
            layout.ensureLayout(for: container)
            #expect(!scroll.hasHorizontalScroller)
            #expect(layout.usedRect(for: container).width <= 300)
            return layout.usedRect(for: container).height
        }
        for (long, short) in pairs { #expect(height(long) > height(short) * 2) }
    }

    @Test func aFencedBlockDrawsTheCodeFill() throws {
        let rep = try RenderSupport.render(ConversationView(items: [.assistant(id: "a", text: "```\nlet x = 1\n```", inProgress: false)]), .fixed(CGSize(width: 300, height: 200)))
        let want = try #require(NSColor(Ink.codeFill).usingColorSpace(.sRGB))
        var found = false
        for y in 0..<rep.pixelsHigh where !found {
            for x in 0..<rep.pixelsWide {
                let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if abs(c.redComponent - want.redComponent) < 0.02, abs(c.greenComponent - want.greenComponent) < 0.02,
                   abs(c.blueComponent - want.blueComponent) < 0.02 { found = true; break }
            }
        }
        #expect(found)
    }
}

@MainActor
struct MarkdownTableTests {
    private let md = "| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |"

    @Test func aTableGivesAlignmentsHeaderAndRows() throws {
        guard case .table(let alignments, let header, let rows)? = MarkdownBlock.parse(md, linkColor: .red).first else {
            Issue.record("no table"); return
        }
        #expect(alignments == [.left, .center, .right])
        #expect(header.count == 3)
        #expect(rows.count == 2)
    }

    @Test func aRaggedRowIsPaddedOrCutToTheHeaderWidth() {
        let short = MarkdownBlock.fit([AttributedString("x")], to: 3)
        let long = MarkdownBlock.fit(["1", "2", "3", "4"].map { AttributedString($0) }, to: 3)
        #expect(short.count == 3)
        #expect(long.count == 3)
        let text = "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |"
        guard case .table(_, let header, let rows)? = MarkdownBlock.parse(text, linkColor: .red).first else {
            Issue.record("no table"); return
        }
        #expect(header.count == 2)
        #expect(rows.allSatisfy { $0.count == 2 })
        #expect(throws: Never.self) { try RenderSupport.render(ConversationView(items: [.assistant(id: "a", text: text, inProgress: false)]), .fixed(CGSize(width: 300, height: 200))) }
    }

    @Test func aTableDrawsTheHairlineColour() throws {
        let rep = try RenderSupport.render(ConversationView(items: [.assistant(id: "a", text: md, inProgress: false)]), .fixed(CGSize(width: 300, height: 200)))
        let want = try #require(NSColor(Ink.border).usingColorSpace(.sRGB))
        var found = false
        for y in 0..<rep.pixelsHigh where !found {
            for x in 0..<rep.pixelsWide {
                let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if abs(c.redComponent - want.redComponent) < 0.02, abs(c.greenComponent - want.greenComponent) < 0.02,
                   abs(c.blueComponent - want.blueComponent) < 0.02 { found = true; break }
            }
        }
        #expect(found)
    }
}
