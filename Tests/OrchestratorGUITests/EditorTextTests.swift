import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct EditorTextTests {
    private let url = URL(fileURLWithPath: "/tmp/x.swift")
    private func load(_ data: Data) -> EditorTextResult { EditorText.load(url, read: { _ in data }) }
    private func reason(_ r: EditorTextResult) -> String? {
        if case .unsupported(let s) = r { return s }
        return nil
    }

    @Test func normalFileLoadsAndEqualsTheFile() {
        #expect(load(Data("let a = 1\nlet b = 2\n".utf8)) == .text("let a = 1\nlet b = 2\n"))
    }

    @Test func limitIsInclusiveAndOversizeNamesTheSize() {
        #expect(load(Data(repeating: 0x61, count: 524_288)) == .text(String(repeating: "a", count: 524_288)))
        let over = reason(load(Data(repeating: 0x61, count: 524_289)))
        #expect(over?.contains("512 KB") == true)
        #expect(over?.contains("(") == true)
    }

    @Test func nulAndInvalidUTF8AndReadFailureAreUnsupported() {
        #expect(reason(load(Data([0x61, 0x00, 0x62]))) != nil)
        #expect(reason(load(Data([0x61, 0xFF, 0xFE]))) != nil)
        struct Boom: Error {}
        #expect(reason(EditorText.load(url, read: { _ in throw Boom() })) != nil)
    }

    @Test func lineRanges() {
        let text = "one\ntwo\nthree"
        #expect(EditorText.lineRange(1, in: text) == NSRange(location: 0, length: 3))
        #expect(EditorText.lineRange(2, in: text) == NSRange(location: 4, length: 3))
        #expect(EditorText.lineRange(3, in: text) == NSRange(location: 8, length: 5))
        #expect(EditorText.lineRange(4, in: text) == nil)
        #expect(EditorText.lineRange(0, in: text) == nil)
        #expect(EditorText.lineRange(-1, in: text) == nil)
    }

    @Test func trailingNewlineDoesNotOpenAnotherLine() {
        #expect(EditorText.lineRange(1, in: "a\n") == NSRange(location: 0, length: 1))
        #expect(EditorText.lineRange(2, in: "a\n") == nil)
        #expect(EditorText.lineRange(2, in: "a\n\nb") == NSRange(location: 2, length: 0))
    }

    @Test func rangesAreInUTF16UnitsAfterEmoji() {
        let text = "😀 hi\nnext"
        #expect(EditorText.lineRange(1, in: text) == NSRange(location: 0, length: 5))
        #expect(EditorText.lineRange(2, in: text) == NSRange(location: 6, length: 4))
    }
}
