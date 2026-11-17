import Foundation
import Testing
@testable import OrchestratorGUI

struct ControlRequestsTests {
    private func request(id: String = "r1", toolUse: String = "t1", input: String = #"{"a":1}"#, extra: String = "") -> String {
        #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"can_use_tool","tool_name":"Bash","input":\#(input),"tool_use_id":"\#(toolUse)"\#(extra)}}"#
    }

    @Test func theAllowFixtureHasOnePendingRequestUntilItsToolResultArrives() throws {
        let lines = try ConversationFixtures.lines("can-use-tool-allow")
        let requestIndex = try #require(lines.firstIndex { $0.contains("control_request") })
        var fold = ControlRequests()
        fold.feed(Array(lines[...requestIndex]))
        #expect(fold.pending.count == 1)
        #expect(fold.pending[0].toolName == "mcp__lean-ctx__ctx_shell")
        #expect(fold.pending[0].reason == "Approve this git commit?")
        fold.feed(Array(lines[(requestIndex + 1)...]))
        #expect(fold.pending.isEmpty)
    }

    @Test func theDenyFixtureHasOnePendingRequestUntilItsToolResultArrives() throws {
        let lines = try ConversationFixtures.lines("can-use-tool-deny")
        let requestIndex = try #require(lines.firstIndex { $0.contains("control_request") })
        var fold = ControlRequests()
        fold.feed(Array(lines[...requestIndex]))
        #expect(fold.pending.count == 1)
        let toolResult = try #require(lines[(requestIndex + 1)...].first { $0.contains("tool_result") })
        fold.feed(toolResult)
        #expect(fold.pending.isEmpty)
    }

    @Test func eachOtherResolverClosesARequest() {
        for closer in [
            #"{"type":"control_cancel_request","request_id":"r1"}"#,
            #"{"type":"result","result":""}"#,
            #"{"type":"system","subtype":"init"}"#,
        ] {
            var fold = ControlRequests()
            fold.feed(request())
            #expect(fold.pending.count == 1)
            fold.feed(closer)
            #expect(fold.pending.isEmpty, "\(closer)")
        }
    }

    @Test func aBadLineOrAMissingFieldAddsNothingAndDoesNotThrow() {
        var fold = ControlRequests()
        fold.feed([
            "not json", "{", #"{"type":"control_request"}"#,
            #"{"type":"control_request","request_id":"x","request":{"subtype":"can_use_tool","input":{}}}"#,
            #"{"type":"control_request","request_id":"x","request":{"subtype":"set_model","tool_name":"B","input":{},"tool_use_id":"t"}}"#,
            #"{"type":"control_request","request":{"subtype":"can_use_tool","tool_name":"B","input":{},"tool_use_id":"t"}}"#,
            #"{"type":"control_request","request_id":"x","request":{"subtype":"can_use_tool","tool_name":"B","tool_use_id":"t"}}"#,
        ])
        #expect(fold.pending.isEmpty)
    }

    @Test func theDisplayTextEscapesHiddenCharactersAndKeepsTheWholeText() {
        let long = String(repeating: "x", count: 3000)
        let input = #"{"c":"a‮b\tc d\ne\#(long)"}"#
        var fold = ControlRequests()
        fold.feed(request(input: input))
        let text = fold.pending[0].text
        #expect(text.contains("\\u{202E}") && text.contains("\\t") && text.contains("\\u{A0}") && text.contains("\\n"))
        #expect(!text.contains("\u{202E}") && !text.contains("\u{A0}"))
        #expect(text.hasSuffix(long + "\"}"))
    }

    @Test func theInputKeepsItsRawBytes() throws {
        let input = #"{"big":12345678901234567890,"f":1.0,"b":true,"s":"a/b"}"#
        var fold = ControlRequests()
        fold.feed(request(input: input, extra: #","decision_reason":"why""#))
        #expect(String(decoding: fold.pending[0].input, as: UTF8.self) == input)
    }
}
