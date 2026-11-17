import Foundation
import Testing
@testable import OrchestratorGUI

struct ControlAnswerWriterTests {
    private func pending(_ fixture: String) throws -> PermissionRequest {
        var fold = ControlRequests()
        let lines = try ConversationFixtures.lines(fixture)
        fold.feed(lines.filter { $0.contains("control_request") })
        return try #require(fold.pending.first)
    }

    private func answerLine(_ inbox: String) throws -> Any {
        let lines = try ConversationFixtures.lines(inbox)
        let line = try #require(lines.first { $0.contains("control_response") })
        return try JSONSerialization.jsonObject(with: Data(line.utf8))
    }

    private func decoded(_ data: Data?) throws -> NSDictionary {
        let bytes = try #require(data)
        let object = try JSONSerialization.jsonObject(with: bytes)
        return try #require(object as? NSDictionary)
    }

    private func tempInbox(create: Bool = true) -> String {
        let path = NSTemporaryDirectory() + "inbox-\(UUID().uuidString).jsonl"
        if create { FileManager.default.createFile(atPath: path, contents: nil) }
        return path
    }

    @Test func theAllowLineMatchesTheRecordedFixture() throws {
        let request = try pending("can-use-tool-allow")
        let line = try decoded(ControlAnswerWriter.allowLine(for: request))
        let expected = try answerLine("can-use-tool-allow-inbox") as? NSDictionary
        #expect(line == expected)
    }

    @Test func theDenyLineMatchesTheRecordedFixture() throws {
        let request = try pending("can-use-tool-deny")
        let line = try decoded(ControlAnswerWriter.denyLine(for: request))
        let expected = try answerLine("can-use-tool-deny-inbox") as? NSDictionary
        #expect(line == expected)
    }

    @Test func updatedInputIsTheRequestInputByteForByte() throws {
        let input = #"{"big":12345678901234567890,"f":1.0,"b":true,"s":"a/b"}"#
        var fold = ControlRequests()
        fold.feed(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":\#(input),"tool_use_id":"t1"}}"#)
        let data = try #require(ControlAnswerWriter.allowLine(for: fold.pending[0]))
        let line = String(decoding: data, as: UTF8.self)
        #expect(line.contains(#""updatedInput":\#(input)}"#))
        #expect(try decoded(Data(line.utf8)).count == 2)
    }

    @Test func anAppendAddsOneNewlineEndedLineAndTwoAppendsAddTwo() throws {
        let request = try pending("can-use-tool-allow")
        let inbox = tempInbox()
        #expect(ControlAnswerWriter.append(request, allow: true, inbox: inbox) == .sent)
        let one = try String(contentsOfFile: inbox, encoding: .utf8)
        #expect(one.hasSuffix("\n") && one.split(separator: "\n").count == 1)
        #expect(ControlAnswerWriter.append(request, allow: false, inbox: inbox) == .sent)
        #expect(try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n").count == 2)
    }

    private let picks = ["Which color?": ["Blue"], "Which fruits?": ["Apple", "Plum"]]

    @Test func theAnswersLineMatchesTheRecordedFixture() throws {
        let request = try pending("ask-user-question")
        let line = try decoded(ControlAnswerWriter.answersLine(for: request, picks: picks))
        let expected = try answerLine("ask-user-question-inbox") as? NSDictionary
        #expect(line == expected)
    }

    @Test func theAnswersLineKeepsEveryOriginalInputField() throws {
        let request = try pending("ask-user-question")
        let line = try decoded(ControlAnswerWriter.answersLine(for: request, picks: picks))
        let updated = try #require(((line["response"] as? NSDictionary)?["response"] as? NSDictionary)?["updatedInput"] as? NSDictionary)
        let original = try #require(try JSONSerialization.jsonObject(with: request.input) as? NSDictionary)
        for (key, value) in original { #expect((updated[key] as? NSObject) == (value as? NSObject)) }
        #expect(updated.count == original.count + 1)
    }

    @Test func anAnswersAppendWritesOneLineAndAMissingInboxFailsWithoutAFile() throws {
        let request = try pending("ask-user-question")
        let inbox = tempInbox()
        #expect(ControlAnswerWriter.appendAnswers(request, picks: picks, inbox: inbox) == .sent)
        #expect(try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n").count == 1)
        let missing = tempInbox(create: false)
        guard case .failed = ControlAnswerWriter.appendAnswers(request, picks: picks, inbox: missing) else {
            Issue.record("expected .failed")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test func aMissingInboxFailsAndCreatesNoFile() throws {
        let inbox = tempInbox(create: false)
        let request = try pending("can-use-tool-allow")
        guard case .failed = ControlAnswerWriter.append(request, allow: true, inbox: inbox) else {
            Issue.record("expected .failed")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: inbox))
    }
}
