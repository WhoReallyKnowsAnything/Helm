import Foundation
import Testing
@testable import Helm

@Suite struct SyntaxTokenizerTests {
    private func pieces(_ text: String, _ language: SyntaxLanguage) -> [String] {
        let ns = text as NSString
        return SyntaxTokenizer.tokenize(text, language: language).map { "\($0.role):\(ns.substring(with: $0.range))" }
    }

    @Test func extensionsMapToLanguages() {
        #expect(SyntaxTokenizer.language(forExtension: "swift") == .swift)
        #expect(SyntaxTokenizer.language(forExtension: "MD") == .markdown)
        #expect(SyntaxTokenizer.language(forExtension: "jsonl") == .json)
        #expect(SyntaxTokenizer.language(forExtension: "yml") == .yaml)
        for e in ["sh", "bash", "zsh", "command", "tool"] { #expect(SyntaxTokenizer.language(forExtension: e) == .shell) }
        #expect(SyntaxTokenizer.language(forExtension: "py") == .plain)
        #expect(SyntaxTokenizer.tokenize("let a = 1", language: .plain).isEmpty)
    }

    @Test func swiftSample() {
        #expect(pieces("let a = \"x // y\" // c\nlet n = 42 /* b */", .swift)
            == ["keyword:let", "string:\"x // y\"", "comment:// c", "keyword:let", "number:42", "comment:/* b */"])
        #expect(pieces("let s = \"\"\"\na \" b\n\"\"\" + x", .swift) == ["keyword:let", "string:\"\"\"\na \" b\n\"\"\""])
    }

    @Test func shellSample() {
        #expect(pieces("if [ $# -gt 0 ]; then echo \"a#b\" # c\nfi", .shell)
            == ["keyword:if", "keyword:then", "string:\"a#b\"", "comment:# c", "keyword:fi"])
        #expect(pieces("echo ${#x} 'it # not'", .shell) == ["string:'it # not'"])
    }

    @Test func jsonSample() {
        #expect(pieces("{\"a\": [1, -2.5e3, true, \"s\", null]}", .json)
            == ["key:\"a\"", "number:1", "number:-2.5e3", "keyword:true", "string:\"s\"", "keyword:null"])
    }

    @Test func yamlSample() {
        #expect(pieces("name: x # c\nlist:\n  - n: 5\n  - \"q\"\nok: true", .yaml)
            == ["key:name", "comment:# c", "key:list", "key:n", "number:5", "string:\"q\"", "key:ok", "keyword:true"])
    }

    @Test func markdownSample() {
        #expect(pieces("# Title\ntext `code` more\n```\nlet x\n```\nend", .markdown)
            == ["heading:# Title", "string:`code`", "string:```\nlet x\n```"])
        #expect(pieces("#nospace", .markdown).isEmpty)
    }

    @Test func emojiGivesUTF16Ranges() {
        let t = SyntaxTokenizer.tokenize("let s = \"😀\" // 😀", language: .swift)
        #expect(t.map(\.range) == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 4), NSRange(location: 13, length: 5)])
    }

    @Test func unterminatedStringAndCommentRunToTheEnd() {
        #expect(pieces("x \"abc\nlet", .swift) == ["string:\"abc\nlet"])
        #expect(pieces("a /* open\nlet", .swift) == ["comment:/* open\nlet"])
    }

    @Test func randomInputGivesInBoundsOrderedNonOverlappingRanges() {
        let pool = Array("\"'/*#`\n :-$\\ab1{}\u{1F600}")
        var seed: UInt64 = 42
        for language in [SyntaxLanguage.swift, .shell, .json, .yaml, .markdown] {
            for _ in 0..<200 {
                var text = ""
                for _ in 0..<60 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    text.append(pool[Int(seed >> 33) % pool.count])
                }
                var last = 0
                for t in SyntaxTokenizer.tokenize(text, language: language) {
                    #expect(t.range.location >= last && t.range.length > 0)
                    last = t.range.location + t.range.length
                    #expect(last <= text.utf16.count)
                }
            }
        }
    }

    @Test func tokenizingHalfAMegabyteOfSwiftTakesUnderASecond() {
        let unit = "import Foundation\n// note\nlet value = \"text\" + 42 /* c */\nfunc go() { return }\n"
        let text = String(repeating: unit, count: 524_288 / unit.utf8.count)
        let start = ContinuousClock.now
        let tokens = SyntaxTokenizer.tokenize(text, language: .swift)
        #expect(!tokens.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
