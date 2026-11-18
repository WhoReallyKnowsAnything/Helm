import Foundation
import Testing
@testable import Helm

@Suite struct PromptMessageTests {
    private func temp(_ name: String, bytes: Int = 8) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func content(_ message: [String: Any]) -> Any? {
        (message["message"] as? [String: Any])?["content"]
    }

    @Test func textOnlyKeepsAPlainStringContent() throws {
        let message = try PromptMessage.build(text: "hello", files: [])
        #expect(message["type"] as? String == "user")
        #expect(content(message) as? String == "hello")
    }

    @Test func imageBecomesATextMarkerThenAnImageBlock() throws {
        let png = try temp("shot.png")
        let blocks = try #require(content(try PromptMessage.build(text: "look", files: [png])) as? [[String: Any]])
        #expect(blocks.count == 3)
        #expect(blocks[0]["text"] as? String == "look")
        #expect(blocks[1]["text"] as? String == "[image: shot.png]")
        let source = try #require(blocks[2]["source"] as? [String: Any])
        #expect(blocks[2]["type"] as? String == "image")
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == Data(repeating: 0x41, count: 8).base64EncodedString())
    }

    @Test func mediaTypeFollowsTheExtension() throws {
        for (name, type) in [("a.JPG", "image/jpeg"), ("a.jpeg", "image/jpeg"), ("a.gif", "image/gif"), ("a.webp", "image/webp")] {
            let blocks = try #require(content(try PromptMessage.build(text: "", files: [try temp(name)])) as? [[String: Any]])
            #expect((blocks.last?["source"] as? [String: Any])?["media_type"] as? String == type)
        }
    }

    @Test func imageOnlyHasNoEmptyTextBlock() throws {
        let blocks = try #require(content(try PromptMessage.build(text: "  ", files: [try temp("a.png")])) as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["text", "image"])
        #expect(blocks[0]["text"] as? String == "[image: a.png]")
    }

    @Test func otherFileGoesIntoTheTextAsItsAbsolutePath() throws {
        let pdf = try temp("notes with space.pdf")
        let text = try #require(content(try PromptMessage.build(text: "read", files: [pdf])) as? String)
        #expect(text == "read\n\nAttached files:\n\(pdf.path)")
    }

    @Test func oversizeImageIsRefusedWithItsName() throws {
        let big = try temp("big.png", bytes: PromptMessage.maxImageBytes + 1)
        #expect(throws: PromptMessage.Failure.tooBig(name: "big.png", bytes: PromptMessage.maxImageBytes + 1)) {
            try PromptMessage.build(text: "x", files: [big])
        }
        #expect(PromptMessage.Failure.tooBig(name: "big.png", bytes: 6_000_000).errorDescription?.contains("big.png") == true)
    }

    @Test func relativeAndControlCharacterPathsAreRefused() throws {
        #expect(throws: PromptMessage.Failure.badPath("rel.png")) {
            try PromptMessage.build(text: "x", files: [URL(string: "rel.png")!])
        }
        let evil = try temp("a\nb.txt")
        #expect(throws: PromptMessage.Failure.self) { try PromptMessage.build(text: "x", files: [evil]) }
    }

    @Test func missingImageIsAnError() {
        #expect(throws: PromptMessage.Failure.self) {
            try PromptMessage.build(text: "x", files: [URL(fileURLWithPath: "/nonexistent/gone.png")])
        }
    }

    @Test func appendWritesTheImageLineToTheInbox() throws {
        let inbox = NSTemporaryDirectory() + "inbox-\(UUID().uuidString).jsonl"
        try Data().write(to: URL(fileURLWithPath: inbox))
        let png = try temp("p.png")
        #expect(InboxDelivery.append("see", inbox: inbox, files: [png]) == .sent)
        let line = try String(contentsOfFile: inbox, encoding: .utf8)
        #expect(line.hasSuffix("\n") && line.filter { $0 == "\n" }.count == 1)
        #expect(line.contains("\"type\":\"image\""))
    }

    @Test func appendRefusesAnOversizeFileAndWritesNothing() throws {
        let inbox = NSTemporaryDirectory() + "inbox-\(UUID().uuidString).jsonl"
        try Data().write(to: URL(fileURLWithPath: inbox))
        let big = try temp("big.png", bytes: PromptMessage.maxImageBytes + 1)
        guard case .refused = InboxDelivery.append("x", inbox: inbox, files: [big]) else {
            Issue.record("expected refused"); return
        }
        #expect(try String(contentsOfFile: inbox, encoding: .utf8).isEmpty)
    }

    @Test func parserShowsAnImageBlockAsAShortLine() {
        let line = #"{"type":"user","isReplay":true,"message":{"role":"user","content":[{"type":"text","text":"hi"},{"type":"text","text":"[image: a.png]"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QQ=="}}]}}"#
        var parser = ConversationParser()
        parser.feed(line)
        #expect(parser.items.contains { if case .user(_, let t) = $0 { return t == "hi\n[image: a.png]" } else { return false } })
    }
}
