import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct DroppedFilesTests {
    private func text(_ paths: String...) -> String {
        DroppedFiles.pasteText(for: paths.map { URL(fileURLWithPath: $0) })
    }

    @Test func screenshotNameEscapesSpacesOnly() {
        #expect(text("/Users/a/Desktop/Screenshot 2026-10-30 at 1.42.40 pm.png")
            == #"/Users/a/Desktop/Screenshot\ 2026-10-30\ at\ 1.42.40\ pm.png"#)
    }

    @Test func twoUrlsJoinWithOneSpace() {
        #expect(text("/a/one.png", "/a/two.png") == "/a/one.png /a/two.png")
    }

    @Test func metacharactersEachGetABackslash() {
        #expect(text("/a/it's $x (1) & co.png") == #"/a/it\'s\ \$x\ \(1\)\ \&\ co.png"#)
        #expect(text("/a/`;!*?[]\"\\.png") == #"/a/\`\;\!\*\?\[\]\"\\.png"#)
    }

    @Test func nonAsciiLettersStayAndTabIsEscaped() {
        #expect(text("/a/café 日本.png") == #"/a/café\ 日本.png"#)
        #expect(text("/a/x\ty") == "/a/x\\\ty")
    }

    @Test func combiningMarkAfterDollarDoesNotHideTheDollar() {
        #expect(text("/a/$\u{0301}b") == "/a/\\$\u{0301}b")
    }

    @Test func nonFileUrlIsDroppedAndEmptyListIsEmpty() throws {
        let web = try #require(URL(string: "https://example.com/a.png"))
        #expect(DroppedFiles.pasteText(for: [web, URL(fileURLWithPath: "/a/b.png")]) == "/a/b.png")
        #expect(DroppedFiles.pasteText(for: []) == "")
        #expect(DroppedFiles.pasteText(for: [web]) == "")
    }

    @Test func pathsWithNewlineCrEscOrOtherControlAreDropped() {
        for bad in ["\n", "\r", "\u{1b}", "\u{3}", "\u{7f}", "\u{9b}"] {
            #expect(text("/a/x\(bad)y.png") == "")
        }
        // ESC [ 201 ~ in a name must never reach the terminal and end a bracketed paste early.
        #expect(text("/a/\u{1b}[201~; rm -rf ~") == "")
        #expect(text("/a/bad\n.png", "/a/good.png") == "/a/good.png")
    }

    @Test func relativeFileUrlIsDropped() throws {
        let relative = try #require(URL(string: "file:-rf"))
        #expect(DroppedFiles.pasteText(for: [relative]) == "")
    }

    @Test func noOutputEndsInNewline() {
        for out in [text("/a/b.png"), text("/a/b c.png", "/d.png"), text("/a/x\ty"), text()] {
            #expect(!out.hasSuffix("\n") && !out.hasSuffix("\r"))
        }
    }

    @Test func bracketedPasteWrapsOnlyWhenOn() {
        #expect(DroppedFiles.wrapped("/a/b.png", bracketed: true) == "\u{1b}[200~/a/b.png\u{1b}[201~")
        #expect(DroppedFiles.wrapped("/a/b.png", bracketed: false) == "/a/b.png")
    }

    // A real shell reads the escaped text back as exactly one word equal to the original name.
    @Test func shellReadsHostileNamesBackVerbatim() throws {
        let names = ["/t/a b", "/t/it's", "/t/$(touch x)", "/t/`id`", "/t/a;b&c|d", "/t/*?[x]", "/t/a\"b\\c",
                     "/t/(1)<2>", "/t/a\tb", "/t/#hash ~tilde", "/t/{a,b}", "/t/!bang", "/t/café"]
        for name in names {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' \(text(name))"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(out == name)
        }
    }
}
