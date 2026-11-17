import Foundation
import Testing
@testable import OrchestratorGUI

struct LineDiffTests {
    private func input(_ json: String) throws -> JSONValue {
        JSONValue(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    private func kinds(_ block: DiffBlock) -> [DiffLine.Kind] { block.lines.map(\.kind) }

    /// Tool-use blocks of the recorded edit-tools fixture, by tool name.
    private func fixtureInput(_ tool: String) throws -> JSONValue {
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines("edit-tools"))
        for case .tool(_, let name, let input, _) in parser.items where name == tool { return input }
        throw CocoaError(.fileReadUnknown)
    }

    @Test func fixtureEditGivesOneRemovedAndOneAdded() throws {
        let blocks = try #require(lineDiff(tool: "Edit", input: try fixtureInput("Edit")))
        #expect(blocks.count == 1)
        #expect(blocks[0].path == "c.txt")
        #expect(blocks[0].lines == [DiffLine(kind: .removed, text: "beta"), DiffLine(kind: .added, text: "BETA")])
    }

    @Test func fixtureWriteGivesOnlyAddedLines() throws {
        let blocks = try #require(lineDiff(tool: "Write", input: try fixtureInput("Write")))
        #expect(blocks == [DiffBlock(path: "d.txt", lines: [DiffLine(kind: .added, text: "hi")])])
    }

    @Test func fixtureCtxPatchReplaceGivesOneRemovedAndOneAdded() throws {
        let blocks = try #require(lineDiff(tool: "mcp__lean-ctx__ctx_patch", input: try fixtureInput("mcp__lean-ctx__ctx_patch")))
        #expect(blocks.count == 1)
        #expect(kinds(blocks[0]) == [.removed, .added])
    }

    @Test func unchangedLinesBetweenTwoChangesStayUnchanged() throws {
        let blocks = try #require(lineDiff(tool: "Edit", input: try input(#"{"old_string":"a\nb\nc","new_string":"A\nb\nC"}"#)))
        #expect(kinds(blocks[0]) == [.removed, .added, .unchanged, .removed, .added])
    }

    @Test func multiEditAndOpsGiveOneBlockPerEdit() throws {
        let multi = try input(#"{"file_path":"f","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}"#)
        #expect(lineDiff(tool: "MultiEdit", input: multi)?.count == 2)
        let ops = try input(#"{"ops":[{"op":"replace_unique","path":"f","old_text":"a","new_text":"b"},{"op":"replace_all","path":"g","find":"c","replace":"d"}]}"#)
        let blocks = try #require(lineDiff(tool: "mcp__lean-ctx__ctx_patch", input: ops))
        #expect(blocks.map(\.path) == ["f", "g"])
    }

    @Test func aNonReplaceCtxPatchOpGivesNil() throws {
        let line = try input(#"{"op":"set_line","path":"f","line":3,"hash":"ab","new_text":"x"}"#)
        #expect(lineDiff(tool: "mcp__lean-ctx__ctx_patch", input: line) == nil)
    }

    @Test func bashAndBadFieldsGiveNil() throws {
        #expect(lineDiff(tool: "Bash", input: try input(#"{"command":"ls"}"#)) == nil)
        #expect(lineDiff(tool: "Edit", input: try input(#"{"old_string":1,"new_string":"x"}"#)) == nil)
        #expect(lineDiff(tool: "Write", input: .null) == nil)
    }
}
