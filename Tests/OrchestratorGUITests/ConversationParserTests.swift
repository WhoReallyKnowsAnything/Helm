import Foundation
import Testing
@testable import OrchestratorGUI

struct ConversationParserTests {
    private func fold(_ fixture: String) throws -> ConversationParser {
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines(fixture))
        return parser
    }

    @Test func aSkillInvocationReadsAsSlashNameAndArgsWithNoTagText() throws {
        let items = try fold("command-message").items
        let texts = items.compactMap { item -> String? in
            if case .user(_, let text) = item { return text } else { return nil }
        }
        #expect(texts == ["/cad-notion-pull", "/cad-notion-pull the open tasks"])
        #expect(!texts.contains { $0.contains("<command-") })
    }

    @Test func aCrossSessionMessageReadsAsFromTheSenderWithOnlyItsBody() throws {
        let items = try fold("cross-session").items
        #expect(items.count == 2)
        guard case .status(_, let text) = items[0] else { Issue.record("not a status row"); return }
        #expect(text == "from run-sleep-20-then-say-done: done")
        guard case .user(_, let typed) = items[1] else { Issue.record("not a user row"); return }
        #expect(typed == "Please explain the <cross-session-message> tag")
    }

    @Test func aTagFirstCrossSessionMessageReadsAsFromTheSenderWithOrWithoutATrailingNote() {
        let tagged = "<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"peer-a\" from-mode=\"prompting\">\nhello\n</cross-session-message>"
        #expect(ConversationParser.crossSession(tagged) == "from peer-a: hello")
        #expect(ConversationParser.crossSession(tagged + "\n\nThis came from another Claude session.") == "from peer-a: hello")
        #expect(ConversationParser.crossSession("Another Claude session sent a message:\n" + tagged) == "from peer-a: hello")
    }

    @Test func aTagFirstSubagentHandBackReadsAsFromTheSubagentWithoutFrameOrIndent() {
        let tagged = "<agent-message from=\"a3c6\">\n[Subagent hand-back] The text below is the final report. The report follows:\n  line one\n    nested\n  line two\n</agent-message>"
        #expect(ConversationParser.crossSession(tagged) == "from subagent a3c6: line one\n  nested\nline two")
        #expect(ConversationParser.crossSession("Another Claude session sent a message:\n" + tagged + "\n\nNote.") == "from subagent a3c6: line one\n  nested\nline two")
    }

    @Test func anAgentMessageTagMidMessageStaysAUserRow() {
        #expect(ConversationParser.crossSession("see <agent-message from=\"x\">b</agent-message>") == nil)
    }

    @Test func aTagMentionedMidMessageIsNotACrossSessionMessage() {
        #expect(ConversationParser.crossSession("see <cross-session-message from=\"x\" from-name=\"p\">b</cross-session-message>") == nil)
    }

    @Test func theTurnStartIsTheFirstUserLinesTimestampUntilTheResultClearsIt() {
        let user = { (ts: String) in #"{"type":"user","isReplay":true,"timestamp":"\#(ts)","message":{"content":"hi"}}"# }
        var parser = ConversationParser()
        parser.feed(user("2026-11-06T12:00:00.500Z"))
        let first = parser.turnStartedAt
        #expect(first == ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")?.addingTimeInterval(0.5))
        parser.feed(user("2026-11-06T12:00:09Z"))
        #expect(parser.turnStartedAt == first)
        parser.feed(#"{"type":"result","result":""}"#)
        #expect(parser.turnStartedAt == nil)
    }

    @Test func aUserLineWithoutATimestampGivesNoStart() {
        var parser = ConversationParser()
        parser.feed(#"{"type":"user","isReplay":true,"message":{"content":"hi"}}"#)
        #expect(parser.turnRunning && parser.turnStartedAt == nil)
    }

    @Test func textTurnGivesAUserThenAnAssistantItemAndTheUnknownLineAddsNothing() throws {
        let items = try fold("text-turn").items
        #expect(items.count == 2)
        guard case .user(_, let said) = items[0], case .assistant(_, let reply, false) = items[1] else {
            Issue.record("unexpected items \(items)")
            return
        }
        #expect(said == "Reply with exactly: hello there")
        #expect(reply == "hello there")
    }

    @Test func turnRunningIsTrueAfterAUserLineAndFalseAfterTheResult() throws {
        let lines = try ConversationFixtures.lines("text-turn")
        var parser = ConversationParser()
        parser.feed(Array(lines[0...1]))
        #expect(parser.turnRunning)
        parser.feed(Array(lines[2...]))
        #expect(!parser.turnRunning)
    }

    @Test func toolCallGivesOneToolItemWithItsResultAttached() throws {
        let items = try fold("tool-call").items
        let tools = items.compactMap { item -> (String, JSONValue, ToolResult?)? in
            if case .tool(_, let name, let input, let result) = item { return (name, input, result) }
            return nil
        }
        #expect(tools.count == 1)
        #expect(tools[0].0 == "mcp__lean-ctx__ctx_read")
        #expect(tools[0].1["path"] == .string("c.txt"))
        #expect(tools[0].2 == ToolResult(text: "alpha\nbeta\ngamma\n", isError: false))
        #expect(items.count == 3, "user, tool call, closing text; thinking is dropped")
    }

    @Test func aResultThatArrivesAfterLaterLinesStillPairs() {
        var parser = ConversationParser()
        parser.feed(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"a":1}}]}}"#)
        parser.feed(#"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"later"}]}}"#)
        parser.feed(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"done","is_error":true}]}}"#)
        #expect(parser.items.count == 2)
        guard case .tool(_, _, _, let result) = parser.items[0] else {
            Issue.record("no tool item")
            return
        }
        #expect(result == ToolResult(text: "done", isError: true))
    }

    @Test func editToolsGiveThreeToolItemsWithTheirRawInputs() throws {
        let tools = try fold("edit-tools").items.compactMap { item -> (String, JSONValue)? in
            if case .tool(_, let name, let input, _) = item { return (name, input) }
            return nil
        }
        #expect(tools.map(\.0) == ["Edit", "Write", "mcp__lean-ctx__ctx_patch"])
        #expect(tools[0].1["old_string"] == .string("beta") && tools[0].1["new_string"] == .string("BETA"))
        #expect(tools[1].1["content"] == .string("hi"))
        #expect(tools[2].1["old_text"] == .string("beta") && tools[2].1["new_text"] == .string("BETA"))
    }

    @Test func deltasGiveOneInProgressItemThenOneFinalItem() throws {
        let lines = try ConversationFixtures.lines("deltas")
        let finalAt = try #require(lines.firstIndex { $0.contains("\"type\":\"assistant\"") })
        var parser = ConversationParser()
        parser.feed(Array(lines[..<finalAt]))
        let streaming = parser.items.filter { if case .assistant(_, _, true) = $0 { return true } else { return false } }
        #expect(streaming.count == 1)
        guard case .assistant(_, let partial, true) = streaming[0] else { return }
        #expect(partial == "hello there")
        parser.feed(Array(lines[finalAt...]))
        let replies = parser.items.compactMap { item -> String? in
            if case .assistant(_, let text, let live) = item { return live ? nil : text }
            return nil
        }
        #expect(replies == ["hello there"])
        #expect(parser.items.count == 2, "user plus one reply; the result adds no second text")
    }

    @Test func aBuiltinResultBecomesOneTextItem() throws {
        let items = try fold("builtin-result").items
        #expect(items.count == 1)
        guard case .assistant(_, let text, false) = items[0] else {
            Issue.record("no text item")
            return
        }
        #expect(text.hasPrefix("## Context Usage"))
    }

    @Test func textTurnResultAddsNoSecondText() throws {
        let texts = try fold("text-turn").items.filter { if case .assistant = $0 { return true } else { return false } }
        #expect(texts.count == 1)
    }

    @Test func interruptParsesThroughAndTheNextTurnYieldsItems() throws {
        let items = try fold("interrupt").items
        #expect(items.contains { if case .assistant(_, let text, false) = $0 { return text.hasPrefix("after") } else { return false } })
    }

    @Test func aModelChangeReadsAsAStatusLineWithNoTagsAndNoTurn() throws {
        let parser = try fold("set-model")
        let statuses = parser.items.compactMap { item -> String? in
            if case .status(_, let text) = item { return text } else { return nil }
        }
        #expect(statuses == ["Set model to `sonnet (claude-sonnet-5-5)`", "Set model to `haiku (claude-haiku-5-5)`"])
        #expect(parser.items.filter { if case .user = $0 { return true } else { return false } }.count == 1)
        #expect(!parser.turnRunning)
    }

    @Test func aSetModelSuccessAddsAStatusLineAndAFailureAddsNone() throws {
        let silent = try ConversationFixtures.lines("set-model").filter { !$0.contains("local-command-stdout") }
        var parser = ConversationParser()
        parser.feed(silent)
        let statuses = parser.items.compactMap { item -> String? in
            if case .status(_, let text) = item { return text } else { return nil }
        }
        #expect(statuses == ["Set model to sonnet (claude-sonnet-5-5)", "Set model to haiku (claude-haiku-5-5)"])
        var failed = ConversationParser()
        failed.feed(#"{"type":"control_response","response":{"subtype":"error","request_id":"r","error":"no"}}"#)
        failed.feed(#"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{}}}"#)
        #expect(failed.items.isEmpty)
    }

    @Test func anMcpStatusReplyReplacesTheServerListAndASetModelStillAddsItsLine() {
        // Shape of the scratchpad spike's reply (2026-11-07), trimmed to 3 servers.
        let reply = #"{"type":"control_response","response":{"subtype":"success","request_id":"app-1","response":{"mcpServers":[{"name":"lean-ctx","status":"connected","scope":"user","source":"user","transport":"stdio"},{"name":"context7","status":"connected","scope":"user","source":"user","transport":"stdio"},{"name":"github","status":"failed","scope":"user","source":"user","transport":"http"}]}}}"#
        var parser = ConversationParser()
        parser.feed(reply)
        #expect(parser.mcpServers.count == 3)
        #expect(parser.mcpServers.first == McpServer(name: "lean-ctx", status: "connected", source: "user"))
        #expect(parser.items.isEmpty)
        parser.feed(#"{"type":"control_response","response":{"subtype":"success","request_id":"m","response":{"model":"claude-sonnet-5-5"}}}"#)
        #expect(parser.items.count == 1)
        #expect(parser.mcpServers.count == 3)
    }

    @Test func anEffortReplyReadsAsAStatusLine() throws {
        let items = try fold("effort").items
        #expect(items == [.status(id: "l1", text: "Set effort level to high (this session only): Comprehensive implementation with extensive testing and documentation")])
    }

    private func texts(_ parser: ConversationParser) -> [String] {
        parser.items.compactMap {
            switch $0 {
            case .user(_, let text), .assistant(_, let text, _): return text
            default: return nil
            }
        }
    }

    @Test func clearDropsTheEarlierTurnAndExposesTheSecondInit() throws {
        let parser = try fold("clear")
        #expect(parser.items.count == 2, "the second turn's user and reply only")
        #expect(!texts(parser).contains { $0.contains("first") })
        #expect(parser.clearCount == 1)
        #expect(parser.slashCommands.contains("context") && parser.skills.contains("review"))
    }

    @Test func aLiveClearLeavesNoItemFromBeforeIt() throws {
        let parser = try fold("clear-live")
        #expect(parser.clearCount == 1 && !parser.turnRunning)
        let all = texts(parser)
        #expect(all.count == 2 && all[0] == "Reply with the single word second.")
    }

    @Test func aResumeKeepsItsHistory() throws {
        let parser = try fold("resume-live")
        #expect(parser.clearCount == 1, "only the clear inside the recorded prefix")
        let all = texts(parser)
        #expect(all.contains("Reply with the single word second.") && all.contains("Reply with the single word third."))
    }

    @Test func anInitKeepsItsMcpServersTerminalCommandsCwdAndSessionId() throws {
        let parser = try fold("init-mcp")
        #expect(parser.mcpServers.count == 14)
        #expect(parser.mcpServers.first == McpServer(name: "example", status: "connected", source: "user"))
        #expect(parser.mcpServers.last == McpServer(name: "example-14", status: "connected", source: "claudeai"))
        #expect(parser.terminalSlashCommands == ["doctor", "color", "focus", "reload-plugins"])
        #expect(parser.cwd == "/tmp/repo")
        #expect(parser.sessionId == "e2589703-f497-463d-8097-0a525735f401")
        let plain = try fold("text-turn")
        #expect(plain.mcpServers.isEmpty && plain.terminalSlashCommands.isEmpty && plain.cwd.isEmpty)
    }

    @Test func anEmptyFoldExposesNoSlashCommands() {
        let parser = ConversationParser()
        #expect(parser.slashCommands.isEmpty && parser.skills.isEmpty)
    }

    @Test func aMalformedLineAndAControlRequestChangeNothing() {
        var parser = ConversationParser()
        parser.feed("{not json")
        parser.feed("")
        parser.feed(#"{"type":"control_request","request_id":"r","request":{"subtype":"can_use_tool","tool_name":"Edit","input":{}}}"#)
        #expect(parser == ConversationParser())
    }
}
