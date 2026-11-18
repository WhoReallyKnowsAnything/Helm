import Foundation
import Testing
@testable import Helm

/// The key rules of the request store (UAT 8), over temp files and fixtures. No key event is needed.
@MainActor
struct CardKeyTests {
    private typealias K = RequestStore.KeyPress

    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func make(_ fixture: String, node: String = "a")
        async throws -> (dir: String, store: RequestStore, entry: RequestStore.Entry, inbox: String) {
        let dir = NSTemporaryDirectory() + "gui-test-key-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = try #require(try ConversationFixtures.lines(fixture).first { $0.contains("control_request") }) + "\n"
        let out = dir + "/\(node).out.jsonl", inbox = dir + "/\(node).in.jsonl"
        FileManager.default.createFile(atPath: out, contents: Data(log.utf8))
        FileManager.default.createFile(atPath: inbox, contents: nil)
        let store = RequestStore()
        store.setSessions([.init(nodeKey: node, outPath: out, inboxPath: inbox, live: true)])
        try await wait { store.entries.count == 1 }
        return (dir, store, try #require(store.entries.first), inbox)
    }

    private func lines(_ inbox: String) throws -> [String] {
        try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func same(_ a: String, _ b: String) throws -> Bool {
        let x = try JSONSerialization.jsonObject(with: Data(a.utf8)) as? NSDictionary
        let y = try JSONSerialization.jsonObject(with: Data(b.utf8)) as? NSDictionary
        return x != nil && x == y
    }

    private func expected(_ name: String) throws -> String {
        try #require(try ConversationFixtures.lines(name).first { $0.contains("control_response") })
    }

    @Test func upAndDownStayInsideTheList() async throws {
        let s = try await make("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let k = s.entry.key
        #expect(s.store.highlight(for: k) == 0)
        #expect(s.store.handle(K(key: .up), for: k))
        #expect(s.store.highlight(for: k) == 0)
        for _ in 0..<10 { #expect(s.store.handle(K(key: .down), for: k)) }
        #expect(s.store.highlight(for: k) == 4)
    }

    @Test func digitTwoPicksTheSecondOptionOfTheHighlightedQuestion() async throws {
        let s = try await make("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let k = s.entry.key
        #expect(s.store.handle(K(key: .digit(2)), for: k))
        #expect(s.store.picks(for: k)["Which color?"] == ["Blue"])
        for _ in 0..<3 { _ = s.store.handle(K(key: .down), for: k) }
        #expect(s.store.handle(K(key: .digit(2)), for: k))
        #expect(s.store.picks(for: k)["Which fruits?"] == ["Pear"])
        #expect(!s.store.handle(K(key: .digit(4)), for: k))
    }

    @Test func returnPicksThenSendsTheRecordedLine() async throws {
        let s = try await make("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let k = s.entry.key
        // Option rows: Red, Blue, Apple, Pear, Plum.
        func pickRow(_ row: Int) {
            while (s.store.highlight(for: k) ?? 0) < row { _ = s.store.handle(K(key: .down), for: k) }
            while (s.store.highlight(for: k) ?? 0) > row { _ = s.store.handle(K(key: .up), for: k) }
            _ = s.store.handle(K(key: .enter), for: k)
        }
        pickRow(1); pickRow(2); pickRow(4)
        #expect(s.store.picks(for: k)["Which color?"] == ["Blue"])
        #expect(try lines(s.inbox).isEmpty)
        // Return on a picked option with every question picked sends.
        #expect(s.store.handle(K(key: .enter), for: k))
        try await wait { s.store.card(for: s.entry).outcome != nil }
        let written = try lines(s.inbox)
        #expect(written.count == 1)
        #expect(try same(written[0], expected("ask-user-question-inbox")))
    }

    @Test func returnOnAPickedOptionBeforeEveryQuestionIsPickedSendsNothing() async throws {
        let s = try await make("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let k = s.entry.key
        _ = s.store.handle(K(key: .enter), for: k)
        _ = s.store.handle(K(key: .enter), for: k)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try lines(s.inbox).isEmpty)
    }

    @Test func returnOnAllowWritesTheAllowLineAtOnce() async throws {
        let s = try await make("can-use-tool-allow")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let k = s.entry.key
        #expect(s.store.highlight(for: k) == nil)
        #expect(s.store.handle(K(key: .enter), for: k))
        #expect(s.store.handle(K(key: .digit(1)), for: k))
        #expect(s.store.highlight(for: k) == 0)
        _ = s.store.handle(K(key: .enter), for: k)
        try await wait { s.store.card(for: s.entry).outcome != nil }
        let written = try lines(s.inbox)
        #expect(written.count == 1)
        #expect(try same(written[0], expected("can-use-tool-allow-inbox")))
    }

    @Test func returnOnDenyWritesTheDenyLine() async throws {
        let s = try await make("can-use-tool-deny")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let k = s.entry.key
        #expect(s.store.handle(K(key: .digit(2)), for: k))
        _ = s.store.handle(K(key: .enter), for: k)
        try await wait { s.store.card(for: s.entry).outcome != nil }
        let written = try lines(s.inbox)
        #expect(written.count == 1)
        #expect(try same(written[0], expected("can-use-tool-deny-inbox")))
    }

    @Test func otherKeysAndModifiedKeysAreNotHandled() async throws {
        let s = try await make("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let k = s.entry.key
        #expect(!s.store.handle(K(key: .other), for: k))
        #expect(!s.store.handle(K(key: .digit(1), modified: true), for: k))
        #expect(!s.store.handle(K(key: .down, modified: true), for: k))
        #expect(!s.store.handle(K(key: .down), for: "request:a:unknown"))
        #expect(s.store.picks(for: k).isEmpty)
    }

    @Test func interruptWritesOneLineToThatNodeOnly() async throws {
        let a = try await make("can-use-tool-allow", node: "a")
        let b = try await make("can-use-tool-allow", node: "b")
        defer { for d in [a.dir, b.dir] { try? FileManager.default.removeItem(atPath: d) } }
        a.store.interrupt(nodeKey: "a")
        try await wait { ((try? lines(a.inbox)) ?? []).count == 1 }
        let written = try lines(a.inbox)
        #expect(written.count == 1)
        #expect(written[0].contains("\"interrupt\""))
        #expect(try lines(b.inbox).isEmpty)
        #expect(a.store.control(for: "a").interrupt == .sending)
    }
}
