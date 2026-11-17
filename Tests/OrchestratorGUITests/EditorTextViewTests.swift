import AppKit
import Testing
@testable import OrchestratorGUI

@MainActor
@Suite struct EditorTextViewTests {
    private let sample = "import Foundation\nfunc go() {}\nlet a = 1\n"

    private func make() -> (NSScrollView, NSTextView) {
        let scroll = EditorTextView.makeScrollView()
        EditorTextView.setText(sample, language: .swift, in: scroll)
        return (scroll, scroll.documentView as! NSTextView)
    }

    @Test func showsTheTextReadOnlyWithRulerFindBarAndColours() {
        let (scroll, textView) = make()
        #expect(textView.string == sample)
        #expect(!textView.isEditable)
        #expect(textView.usesFindBar)
        #expect(scroll.hasVerticalRuler && scroll.rulersVisible && scroll.verticalRulerView is LineNumberRuler)
        let at = (sample as NSString).range(of: "func").location
        #expect(textView.textStorage?.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == EditorInk.keyword)
        let plain = (sample as NSString).range(of: "go").location
        #expect(textView.textStorage?.attribute(.foregroundColor, at: plain, effectiveRange: nil) as? NSColor == EditorInk.text)
    }

    @Test func firstOpenShowsTheFirstCharacterRightOfTheRuler() {
        let scroll = EditorTextView.makeScrollView()
        EditorTextView.setText(String(repeating: String(repeating: "x", count: 200) + "\n", count: 5), language: .swift, in: scroll)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.origin.x == -scroll.contentView.contentInsets.left)
    }

    @Test func scrollRequestSelectsExactlyTheLine() {
        let (scroll, textView) = make()
        #expect(EditorTextView.select(line: 3, in: scroll))
        #expect(textView.selectedRange() == NSRange(location: 31, length: 9))
        #expect(!EditorTextView.select(line: 9, in: scroll))
        #expect(textView.selectedRange() == NSRange(location: 31, length: 9))
    }

    private func editable(_ onEdit: @escaping (String) -> Void) -> (NSScrollView, NSTextView, EditorTextView.Coordinator) {
        let (scroll, textView) = make()
        let view = EditorTextView(text: sample, language: .swift, request: nil, isEditable: true, onEdit: onEdit)
        let coordinator = view.makeCoordinator()
        coordinator.language = .swift
        coordinator.onEdit = onEdit
        textView.delegate = coordinator
        textView.isEditable = true
        return (scroll, textView, coordinator)
    }

    @Test func userInsertCallsTheStoreOnceAndStaysColoured() {
        var seen: [String] = []
        let (_, textView, _) = editable { seen.append($0) }
        textView.insertText("let ", replacementRange: NSRange(location: 0, length: 0))
        #expect(seen.count == 1)
        #expect(seen.first == textView.string)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == EditorInk.keyword)
    }

    @Test func doubleQuoteStaysAscii() {
        let (_, textView, _) = editable { _ in }
        textView.insertText("\"", replacementRange: NSRange(location: 0, length: 0))
        #expect(textView.string.hasPrefix("\"import"))
    }

    @Test func undoRestoresTheEarlierText() {
        let (scroll, textView, _) = editable { _ in }
        // An undo manager comes from the window, so the view needs one.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = scroll
        let undo = textView.undoManager
        #expect(undo != nil)
        undo?.groupsByEvent = false
        undo?.beginUndoGrouping()
        textView.insertText("zz", replacementRange: NSRange(location: 0, length: 0))
        undo?.endUndoGrouping()
        #expect(textView.string.hasPrefix("zz"))
        undo?.undo()
        #expect(textView.string == sample)
    }

    @Test func programTextDoesNotCallOnEdit() {
        var calls = 0
        let (scroll, _, _) = editable { _ in calls += 1 }
        EditorTextView.setText("other\n", language: .swift, in: scroll)
        #expect(calls == 0)
    }

    @Test func readOnlyViewRejectsAnInsert() {
        let (_, textView) = make()
        textView.isEditable = false
        textView.insertText("zz", replacementRange: NSRange(location: 0, length: 0))
        #expect(textView.string == sample)
    }
}
