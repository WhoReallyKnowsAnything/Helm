import Foundation
import Testing
@testable import Helm

/// The whole path over temp files, no app and no tmux: database row, store, prompt box model, inbox, replayed events.
@MainActor
struct ConversationFlowTests {
    private func append(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func aSentMessageReachesTheInboxAndTheRepliesReachTheStore() async throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let inbox = fx.path + "/alpha.in.jsonl", out = fx.path + "/alpha.out.jsonl"
        FileManager.default.createFile(atPath: inbox, contents: nil)
        FileManager.default.createFile(atPath: out, contents: nil)
        try fx.sql("UPDATE sessions SET inbox_path = '\(inbox)', out_path = '\(out)' WHERE agent_id = 'alpha'")

        guard case .loaded(let state) = WorkerDatabase(project: fx.path).read() else { Issue.record("not loaded"); return }
        let row = try #require(state.rows.first { $0.agentId == "alpha" })
        #expect(row.inboxPath == inbox && row.outPath == out)

        let store = ConversationStore(path: try #require(row.outPath))
        let model = ConversationHost.makeModel(inboxPath: row.inboxPath)
        await model.send("/context")
        #expect(model.sent)
        let sent = try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n")
        #expect(sent.count == 1)

        let user = #"{"type":"user","isReplay":true,"session_id":"s","message":{"content":"/context"}}"#
        try append(user + "\n", to: out)
        // One session id for every spliced line: a changed id reads as /clear and drops the earlier items.
        func oneSession(_ name: String) throws -> String {
            try ConversationFixtures.lines(name).joined(separator: "\n")
                .replacingOccurrences(of: #""session_id":"[^"]*""#, with: #""session_id":"s""#, options: .regularExpression) + "\n"
        }
        try append(try oneSession("deltas"), to: out)
        try append(try oneSession("builtin-result"), to: out)

        func texts() -> [String] {
            store.items.compactMap {
                switch $0 {
                case .user(_, let text), .assistant(_, let text, _): return text
                default: return nil
                }
            }
        }
        for _ in 0..<100 where !texts().contains(where: { $0.contains("Tokens: 12k") }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(texts().contains("/context"))
        #expect(texts().contains("hello there"))
        #expect(texts().contains { $0.contains("Tokens: 12k") })
    }
}
