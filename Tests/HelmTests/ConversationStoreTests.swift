import Combine
import Foundation
import Testing
@testable import Helm

@MainActor
struct ConversationStoreTests {
    private let userLine = #"{"type":"user","isReplay":true,"session_id":"s","message":{"content":"hi"}}"#
    private let replyLine = #"{"type":"assistant","session_id":"s","message":{"id":"m1","content":[{"type":"text","text":"yo"}]}}"#

    private func folder() throws -> String {
        let path = NSTemporaryDirectory() + "store-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func append(_ text: String, to path: String) throws {
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    private func wait(tries: Int = 100, _ what: () -> Bool) async -> Bool {
        for _ in 0..<tries where !what() { try? await Task.sleep(nanoseconds: 50_000_000) }
        return what()
    }

    @Test func linesWrittenAfterCreationAppearAndASecondStoreSeesTheSameHistory() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        let store = ConversationStore(path: out)
        try append(userLine + "\n" + replyLine + "\n", to: out)
        #expect(await wait { store.items.count == 2 })
        let second = ConversationStore(path: out)
        #expect(await wait { second.items == store.items })
    }

    @Test func theStorePublishesTheInitServersTerminalCommandsCwdAndSessionId() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        try append(try ConversationFixtures.lines("init-mcp").joined(separator: "\n") + "\n", to: out)
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines("init-mcp"))
        let store = ConversationStore(path: out)
        #expect(await wait { store.mcpServers.count == 14 })
        #expect(store.mcpServers == parser.mcpServers)
        #expect(store.terminalSlashCommands == ["doctor", "color", "focus", "reload-plugins"])
        #expect(store.cwd == "/tmp/repo" && store.sessionId == parser.sessionId)
    }

    @Test func aClearDropsThePendingEchoRowsAndKeepsOnlyPostClearItems() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        let store = ConversationStore(path: out)
        store.echo("/clear")
        #expect(store.pending.count == 1)
        try append(try ConversationFixtures.lines("clear-live").joined(separator: "\n") + "\n", to: out)
        #expect(await wait { store.items.count == 2 })
        #expect(store.pending.isEmpty)
        guard case .user(_, let said) = store.items[0] else { Issue.record("no user item"); return }
        #expect(said == "Reply with the single word second.")
    }

    @Test func theStartIsTheLogTimestampOrTheClockAndClearsAfterTheResult() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stamped = dir + "/a.jsonl"
        let store = ConversationStore(path: stamped)
        try append(#"{"type":"user","isReplay":true,"timestamp":"2026-11-06T12:00:00Z","message":{"content":"hi"}}"# + "\n", to: stamped)
        let expected = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")
        #expect(await wait { store.turnStartedAt == expected })

        let plain = dir + "/b.jsonl"
        let second = ConversationStore(path: plain)
        try append(userLine + "\n", to: plain)
        #expect(await wait { second.turnStartedAt != nil })
        #expect(abs(try #require(second.turnStartedAt).timeIntervalSinceNow) < 5)
        try append(#"{"type":"result","result":""}"# + "\n", to: plain)
        #expect(await wait { second.turnStartedAt == nil })
    }

    @Test func appendsThroughAHeldHandleShowWithoutAFolderEvent() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        try append("", to: out)
        let handle = try #require(FileHandle(forWritingAtPath: out))
        defer { try? handle.close() }
        let store = ConversationStore(path: out)
        try? await Task.sleep(nanoseconds: 500_000_000)
        try handle.write(contentsOf: Data((userLine + "\n").utf8))
        try? await Task.sleep(nanoseconds: 500_000_000)
        try handle.write(contentsOf: Data((replyLine + "\n").utf8))
        #expect(await wait(tries: 20) { store.items.count == 2 })
    }

    @Test func anInboxWriteInTheSameFolderPublishesNothing() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        try append(userLine + "\n", to: out)
        let store = ConversationStore(path: out)
        #expect(await wait { store.items.count == 1 })
        let before = store.items
        var published = 0
        let watch = store.objectWillChange.sink { published += 1 }
        try append("{\"type\":\"user\"}\n", to: dir + "/inbox.jsonl")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(published == 0 && store.items == before)
        watch.cancel()
    }

    @Test func aShorterReplacementResetsAndShowsOnlyTheNewContent() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        try append(userLine + "\n" + replyLine + "\n", to: out)
        let store = ConversationStore(path: out)
        #expect(await wait { store.items.count == 2 })
        try Data((userLine + "\n").utf8).write(to: URL(fileURLWithPath: out))
        #expect(await wait { store.items.count == 1 })
    }

    @Test func anEndedSessionStopsEveryRunningSubagent() async throws {
        for (name, last) in [("subagent", 8), ("subagent-background", 21)] {
            let dir = try folder()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let out = dir + "/out.jsonl"
            try append(try ConversationFixtures.lines(name)[0...last].joined(separator: "\n") + "\n", to: out)
            let store = ConversationStore(path: out)
            #expect(await wait { store.subagents.first?.running == true }, "\(name)")
            store.setEnded(true)
            #expect(store.subagents.first?.running == false, "\(name)")
        }
    }

    @Test func aNewStoreOverAResumeSeedShowsOnlyTheSeed() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        try append(#"{"type":"user","isReplay":true,"session_id":"old","message":{"content":"old text"}}"# + "\n", to: out)
        let seed = [
            #"{"type":"user","isReplay":true,"session_id":"r","message":{"content":"q1"}}"#,
            #"{"type":"assistant","session_id":"r","message":{"id":"a1","content":[{"type":"text","text":"a1"}]}}"#,
            #"{"type":"user","isReplay":true,"session_id":"r","message":{"content":"q2"}}"#,
            #"{"type":"assistant","session_id":"r","message":{"id":"a2","content":[{"type":"text","text":"a2"}]}}"#,
            #"{"type":"result","subtype":"success","session_id":"r"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(seed.utf8).write(to: URL(fileURLWithPath: out))
        let store = ConversationStore(path: out)
        #expect(await wait { store.items.count == 4 })
        let texts = store.items.map { item -> String in
            switch item {
            case .user(_, let text): return text
            case .assistant(_, let text, _): return text
            default: return ""
            }
        }
        #expect(texts == ["q1", "a1", "q2", "a2"])
        #expect(!store.turnRunning)
    }

    @Test func anEchoedLineShowsAtOnceAndAReplayReplacesIt() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        let store = ConversationStore(path: out)
        store.echo("hi")
        #expect(store.pending == [.user(id: "p1", text: "hi")])
        try append(userLine + "\n", to: out)
        #expect(await wait { store.items.count == 1 })
        #expect(store.pending.isEmpty)
        #expect(store.items.filter { if case .user(_, "hi") = $0 { true } else { false } }.count == 1)
    }

    @Test func eachReplayClearsOneEchoedLine() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        let store = ConversationStore(path: out)
        store.echo("a")
        store.echo("b")
        try append(userLine + "\n", to: out)
        #expect(await wait { store.items.count == 1 })
        #expect(store.pending == [.user(id: "p2", text: "b")])
        try append(userLine + "\n", to: out)
        #expect(await wait { store.items.count == 2 })
        #expect(store.pending.isEmpty)
    }

    /// User rows with this text in what the view shows (`items + pending`).
    private func shown(_ store: ConversationStore, _ text: String) -> Int {
        (store.items + store.pending).filter { if case .user(_, let said) = $0 { said == text } else { false } }.count
    }

    private func replayed(_ store: ConversationStore) -> Int {
        store.items.filter { if case .user = $0 { true } else { false } }.count
    }

    @Test func aSentMessageShowsOnceWhenTheEchoComesBeforeTheReplay() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        let store = ConversationStore(path: out)
        store.echo("Reply with exactly: hello there")
        try append(try ConversationFixtures.lines("text-turn").joined(separator: "\n") + "\n", to: out)
        #expect(await wait { store.items.count == 2 && !store.turnRunning })
        #expect(shown(store, "Reply with exactly: hello there") == 1)
        #expect(store.pending.isEmpty)
    }

    @Test func aSentMessageShowsOnceWhenTheReplayIsReadBeforeTheEcho() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        let store = ConversationStore(path: out)
        let before = store.userRows
        try append(try ConversationFixtures.lines("text-turn").prefix(2).joined(separator: "\n") + "\n", to: out)
        #expect(await wait { replayed(store) == 1 })
        store.echo("Reply with exactly: hello there", after: before)
        #expect(shown(store, "Reply with exactly: hello there") == 1)
        #expect(store.pending.isEmpty)
    }

    @Test func aSentMessageShowsOnceWhenTheReplyAndResultAreAlreadyIn() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        let store = ConversationStore(path: out)
        let before = store.userRows
        try append(try ConversationFixtures.lines("text-turn").joined(separator: "\n") + "\n", to: out)
        #expect(await wait { store.items.count == 2 && !store.turnRunning })
        store.echo("Reply with exactly: hello there", after: before)
        #expect(shown(store, "Reply with exactly: hello there") == 1)
        #expect(store.pending.isEmpty)
    }

    @Test func aSkillSentFromTheBoxShowsOnceInEitherOrder() async throws {
        let line = try #require(ConversationFixtures.lines("command-message").first)
        for echoFirst in [true, false] {
            let dir = try folder()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let out = dir + "/out.jsonl"
            let store = ConversationStore(path: out)
            let before = store.userRows
            if echoFirst { store.echo("/cad-notion-pull", after: before) }
            try append(line + "\n", to: out)
            #expect(await wait { replayed(store) == 1 })
            if !echoFirst { store.echo("/cad-notion-pull", after: before) }
            #expect(shown(store, "/cad-notion-pull") == 1)
            #expect(store.pending.isEmpty)
        }
    }

    @Test func twoQueuedMessagesEachClearOneEcho() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        let store = ConversationStore(path: out)
        store.echo("Reply with the single word ready.")
        store.echo("Reply with the single word pong.")
        // The fixture's second user line carries another session_id, which the parser reads as /clear; give both one id.
        let queued = try ConversationFixtures.lines("turn-queued").filter { $0.contains(#""type":"user""#) }
            .map { $0.replacingOccurrences(of: "3408f316-89f9-4690-8afb-569cf3e69022", with: "39627f1e-9a87-48da-b4e6-7dea5e1a9e68") }
        try append(queued.joined(separator: "\n") + "\n", to: out)
        #expect(await wait { replayed(store) == 2 })
        #expect(shown(store, "Reply with the single word ready.") == 1)
        #expect(shown(store, "Reply with the single word pong.") == 1)
        #expect(store.pending.isEmpty)
    }

    @Test func aMissingFolderCreatesNoWatcherAndPublishesNothing() async throws {
        let store = ConversationStore(path: NSTemporaryDirectory() + "nope-" + UUID().uuidString + "/out.jsonl")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(store.items.isEmpty)
    }
}
