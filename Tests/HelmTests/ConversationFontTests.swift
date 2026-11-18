import AppKit
import SwiftUI
import Testing
@testable import Helm

@MainActor
struct ConversationFontTests {
    /// A throwaway suite, so no test touches `.standard`.
    private func defaults() -> UserDefaults {
        let name = "gui-test-conversation-font-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func stored(_ family: String?, _ size: Double?) -> ConversationFont {
        let store = defaults()
        if let family { store.set(family, forKey: ConversationFont.familyKey) }
        if let size { store.set(size, forKey: ConversationFont.sizeKey) }
        return ConversationFont(defaults: store)
    }

    @Test func theDefaultIsSFMono13AndMatchesKitTypeForEveryRole() {
        let font = stored(nil, nil)
        #expect(font.family == "SF Mono")
        #expect(font.size == 13)
        for role in KitType.allCases { #expect(font.nsFont(for: role) == role.nsFont) }
    }

    @Test func aStoredValueResolvesInBothFontForms() {
        let font = stored("Menlo", 17)
        let body = font.nsFont(for: .body)
        #expect(body.familyName == "Menlo")
        #expect(body.pointSize == 17)
        #expect(font.nsFont(for: .label).pointSize == 16)
        #expect(font.nsFont(for: .title).pointSize == 17)
        #expect(font.font(for: .body) != KitType.body.font)
    }

    @Test func aMissingFamilyFallsBackToSFMono() {
        let font = stored("Not A Real Font Family", 13)
        for role in KitType.allCases { #expect(font.nsFont(for: role) == role.nsFont) }
    }

    @Test func theSizeClampsTo10Through24() {
        #expect(stored(nil, 4).size == 10)
        #expect(stored(nil, 99).size == 24)
        #expect(ConversationFont(family: "SF Mono", size: 18).size == 18)
    }

    @Test func thePromptFieldShowsSixLinesUnclippedAtEverySize() {
        for size in [10.0, 24.0] {
            let setting = ConversationFont(family: "SF Mono", size: size)
            let font = setting.nsFont(for: .body)
            let six = CGFloat(ConversationFont.promptLines) * (font.ascender - font.descender + font.leading)
            #expect(setting.promptFieldMaxHeight >= six)
            #expect(setting.promptFieldMaxHeight.truncatingRemainder(dividingBy: 4) == 0)
        }
        #expect(ConversationFont(family: "SF Mono", size: 10).promptFieldMaxHeight == Metric.promptFieldMaxHeight)
        #expect(ConversationFont(family: "SF Mono", size: 24).promptFieldMaxHeight > Metric.promptFieldMaxHeight)
    }

    @Test func theFamilyListStartsWithTheDefaultAndHasNoRepeats() {
        let families = ConversationFont.loadFamilies()
        #expect(families.first == "SF Mono")
        #expect(Set(families).count == families.count)
        #expect(families.contains("Menlo"))
    }

    @Test func aFontChangeKeepsSelectionAndUndoInTheEditor() throws {
        let scroll = EditorTextView.makeScrollView()
        EditorTextView.setText("one\ntwo\nthree\n", language: .plain, in: scroll)
        let textView = try #require(scroll.documentView as? NSTextView)
        textView.isEditable = true
        // An undo manager comes from the window, so the view needs one.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = scroll
        let undo = try #require(textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        textView.insertText("zz", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        let big = ConversationFont(family: "SF Mono", size: 20)
        EditorTextView.restyle(font: big, in: scroll)
        #expect(textView.selectedRange() == NSRange(location: 4, length: 3))
        #expect(undo.canUndo)
        #expect((textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 20)
        #expect((textView.typingAttributes[.font] as? NSFont)?.pointSize == 20)
    }

    @Test func aChangedSettingChangesTheFontTheTranscriptBuilds() {
        let items: [ConversationItem] = [.assistant(id: "a", text: "hello", inProgress: false)]
        func bodyFont(_ setting: ConversationFont) -> NSFont? {
            let text = TranscriptText.build(items, accent: Ink.accent, expanded: [], font: setting)
            return text.attribute(.font, at: (text.string as NSString).range(of: "hello").location, effectiveRange: nil) as? NSFont
        }
        #expect(bodyFont(stored(nil, nil)) == KitType.body.nsFont)
        #expect(bodyFont(stored(nil, 20))?.pointSize == 20)
        #expect(bodyFont(stored("Menlo", 13))?.familyName == "Menlo")
    }
}
