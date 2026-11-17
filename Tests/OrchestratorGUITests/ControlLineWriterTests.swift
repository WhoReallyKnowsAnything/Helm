import Foundation
import Testing
@testable import OrchestratorGUI

struct ControlLineWriterTests {
    private func tempInbox(create: Bool = true) -> String {
        let path = NSTemporaryDirectory() + "inbox-\(UUID().uuidString).jsonl"
        if create { FileManager.default.createFile(atPath: path, contents: nil) }
        return path
    }

    private func fixtureLine(_ name: String, containing token: String) throws -> NSDictionary {
        let all = try ConversationFixtures.lines(name)
        let line = try #require(all.first { $0.contains(token) })
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? NSDictionary)
    }

    private func withoutId(_ object: Any) throws -> NSDictionary {
        let dict = try #require(object as? NSDictionary)
        let copy = NSMutableDictionary(dictionary: dict)
        copy.removeObject(forKey: "request_id")
        return copy
    }

    private func decoded(_ data: Data?) throws -> NSDictionary {
        let bytes = try #require(data)
        let object = try JSONSerialization.jsonObject(with: bytes)
        return try #require(object as? NSDictionary)
    }

    @Test func onlyInterruptSetModelAndMcpStatusSubtypesExist() {
        #expect(ControlLineWriter.Subtype.allCases.map(\.rawValue) == ["interrupt", "set_model", "mcp_status"])
    }

    @Test func noEmittedLineHoldsAnAnswerKey() throws {
        let lines = [ControlLineWriter.interruptLine(), ControlLineWriter.mcpStatusLine()] + ControlLineWriter.models.map { ControlLineWriter.setModelLine($0) }
        for data in lines {
            let bytes = try #require(data)
            let text = String(decoding: bytes, as: UTF8.self)
            for token in ["behavior", "updatedInput", "can_use_tool"] { #expect(!text.contains(token)) }
        }
    }

    @Test func theInterruptLineMatchesTheFixtureExceptTheId() throws {
        let line = try decoded(ControlLineWriter.interruptLine())
        let expected = try fixtureLine("interrupt-tool-inbox", containing: "control_request")
        #expect(try withoutId(line) == withoutId(expected))
    }

    @Test func theSetModelLineMatchesTheFixtureShapeExceptTheIdAndModel() throws {
        let line = try decoded(ControlLineWriter.setModelLine("sonnet"))
        let expected = try fixtureLine("set-model-inbox", containing: "\"sonnet\"")
        #expect(try withoutId(line) == withoutId(expected))
    }

    @Test func theMcpStatusLineIsAControlRequestWithAnAppId() throws {
        let inbox = tempInbox()
        #expect(ControlLineWriter.appendMcpStatus(inbox: inbox) == .sent)
        let text = try String(contentsOfFile: inbox, encoding: .utf8)
        let line = try decoded(Data(try #require(text.split(separator: "\n").first).utf8))
        #expect(line["type"] as? String == "control_request")
        #expect((line["request"] as? NSDictionary)?["subtype"] as? String == "mcp_status")
        #expect((line["request_id"] as? String)?.hasPrefix("app-") == true)
    }

    @Test func twoInterruptsGetTwoIds() throws {
        let one = try decoded(ControlLineWriter.interruptLine())["request_id"] as? String
        let two = try decoded(ControlLineWriter.interruptLine())["request_id"] as? String
        #expect(one != nil && one != two)
    }

    @Test func appendsAddOneNewlineEndedLineEach() throws {
        let inbox = tempInbox()
        #expect(ControlLineWriter.appendInterrupt(inbox: inbox) == .sent)
        #expect(ControlLineWriter.appendSetModel("haiku", inbox: inbox) == .sent)
        let text = try String(contentsOfFile: inbox, encoding: .utf8)
        #expect(text.hasSuffix("\n") && text.split(separator: "\n").count == 2)
    }

    @Test func theEffortCallAddsTheFixtureUserLine() throws {
        let inbox = tempInbox()
        #expect(ControlLineWriter.appendEffort("high", inbox: inbox) == .sent)
        let text = try String(contentsOfFile: inbox, encoding: .utf8)
        let written = try #require(text.split(separator: "\n").first)
        let object = try JSONSerialization.jsonObject(with: Data(written.utf8))
        let expected = try fixtureLine("effort-inbox", containing: "/effort")
        #expect(object as? NSDictionary == expected)
    }

    @Test func aBadLevelAndABadModelWriteNothing() throws {
        let inbox = tempInbox()
        guard case .refused = ControlLineWriter.appendEffort("turbo", inbox: inbox) else { Issue.record("level"); return }
        guard case .refused = ControlLineWriter.appendSetModel("gpt", inbox: inbox) else { Issue.record("model"); return }
        #expect(ControlLineWriter.setModelLine("gpt") == nil)
        #expect(try String(contentsOfFile: inbox, encoding: .utf8).isEmpty)
    }

    @Test func aMissingInboxFailsAndCreatesNoFile() {
        let inbox = tempInbox(create: false)
        guard case .failed = ControlLineWriter.appendInterrupt(inbox: inbox) else { Issue.record("interrupt"); return }
        guard case .failed = ControlLineWriter.appendSetModel("opus", inbox: inbox) else { Issue.record("model"); return }
        guard case .failed = ControlLineWriter.appendEffort("low", inbox: inbox) else { Issue.record("effort"); return }
        #expect(!FileManager.default.fileExists(atPath: inbox))
    }
}
