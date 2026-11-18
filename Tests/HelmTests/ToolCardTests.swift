import Foundation
import SwiftUI
import Testing
@testable import Helm

@MainActor
struct ToolCardTests {
    private func input(_ json: String) throws -> JSONValue {
        JSONValue(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    @Test func summaryPicksTheUsualKeyOrFirstString() throws {
        #expect(toolSummary(try input(#"{"command":"ls -la","description":"list"}"#)) == "ls -la")
        #expect(toolSummary(try input(#"{"path":"c.txt","mode":"full"}"#)) == "c.txt")
        #expect(toolSummary(try input(#"{"zeta":"z","alpha":"a","n":1}"#)) == "a")
        #expect(toolSummary(try input("{}")) == "")
        #expect(toolSummary(.null) == "")
    }

    @Test func aLongMultiLineValueIsCutToOneLine() throws {
        let long = String(repeating: "x", count: 500)
        let summary = toolSummary(try input(#"{"command":"\#(long)\nsecond"}"#))
        #expect(!summary.contains("\n"))
        #expect(summary.count == toolSummaryCap + 1)
    }

    private func fixtureTool() throws -> (String, JSONValue, ToolResult?) {
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines("tool-call"))
        for case .tool(_, let name, let input, let result) in parser.items { return (name, input, result) }
        throw CocoaError(.fileReadUnknown)
    }

    /// One tool line in the transcript view, drawn as the conversation draws it.
    private func card(_ item: ConversationItem, expanded: Bool) throws -> NSBitmapImageRep {
        try RenderSupport.render(
            TranscriptTextView(items: [item], accent: Ink.swatch(for: .blue), expanded: expanded ? [item.id, TranscriptText.runKey(item.id)] : [], onToggle: { _ in }),
            .fixed(CGSize(width: 400, height: textHeight(item, expanded: expanded))))
    }

    /// The laid-out height of the transcript text at 400 pt wide.
    private func textHeight(_ item: ConversationItem, expanded: Bool) throws -> CGFloat {
        let scroll = TranscriptTextView.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        let textView = try #require(scroll.documentView as? NSTextView)
        textView.textStorage?.setAttributedString(TranscriptText.build([item], accent: Ink.accent, expanded: expanded ? [item.id, TranscriptText.runKey(item.id)] : []))
        scroll.scrollToBottom()
        return textView.frame.height
    }

    @Test func anExpandedCardIsTallerThanACollapsedOne() throws {
        let (name, tool, result) = try fixtureTool()
        let item = ConversationItem.tool(id: "t", name: name, input: tool, result: result)
        #expect(try textHeight(item, expanded: true) > textHeight(item, expanded: false))
    }

    private func tool(_ name: String) throws -> (JSONValue, ToolResult?) {
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines("edit-tools"))
        for case .tool(_, let n, let input, let result) in parser.items where n == name { return (input, result) }
        throw CocoaError(.fileReadUnknown)
    }

    /// `tolerance` is 4/255 for flat fills; a thin antialiased glyph needs a wider one.
    private func draws(_ colour: Color, in rep: NSBitmapImageRep, tolerance: CGFloat = 4 / 255) throws -> Bool {
        let want = try #require(NSColor(colour).usingColorSpace(.sRGB))
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if abs(c.redComponent - want.redComponent) <= tolerance, abs(c.greenComponent - want.greenComponent) <= tolerance,
                   abs(c.blueComponent - want.blueComponent) <= tolerance { return true }
            }
        }
        return false
    }

    private func expandedCard(_ name: String) throws -> NSBitmapImageRep {
        let (input, result) = try tool(name)
        return try card(.tool(id: "t", name: name, input: input, result: result), expanded: true)
    }

    @Test func editAndPatchCardsDrawAddedAndRemovedFills() throws {
        for name in ["Edit", "mcp__lean-ctx__ctx_patch"] {
            let rep = try expandedCard(name)
            #expect(try draws(Ink.diffAddedFill, in: rep))
            #expect(try draws(Ink.diffRemovedFill, in: rep))
        }
    }

    @Test func aWriteCardDrawsOnlyTheAddedFill() throws {
        let rep = try expandedCard("Write")
        #expect(try draws(Ink.diffAddedFill, in: rep))
        #expect(try !draws(Ink.diffRemovedFill, in: rep))
    }

    @Test func aCollapsedLineDrawsTheDoneGlyphOnlyForOkAndTheFailedGlyphOnlyForAnError() throws {
        let call = try input(#"{"command":"ls"}"#)
        func line(_ result: ToolResult?) throws -> NSBitmapImageRep {
            try card(.tool(id: "t", name: "Bash", input: call, result: result), expanded: false)
        }
        let running = try line(nil)
        let ok = try line(ToolResult(text: "a", isError: false))
        let failed = try line(ToolResult(text: "a", isError: true))
        let glyph: CGFloat = 20 / 255
        #expect(try !draws(Ink.toolDone, in: running, tolerance: glyph) && !draws(Ink.toolFailed, in: running, tolerance: glyph))
        #expect(try draws(Ink.toolDone, in: ok, tolerance: glyph) && !draws(Ink.toolFailed, in: ok, tolerance: glyph))
        #expect(try draws(Ink.toolFailed, in: failed, tolerance: glyph) && !draws(Ink.toolDone, in: failed, tolerance: glyph))
    }

    @Test func aBashCardDrawsNeitherFill() throws {
        let input = try input(#"{"command":"ls"}"#)
        let rep = try card(.tool(id: "t", name: "Bash", input: input, result: ToolResult(text: "a", isError: false)), expanded: true)
        #expect(try !draws(Ink.diffAddedFill, in: rep))
        #expect(try !draws(Ink.diffRemovedFill, in: rep))
    }
}
