import Foundation
import SwiftUI
import Testing
@testable import OrchestratorGUI

/// Recorded request to card to inbox line, over temp files: no app, no tmux, no live claude.
@MainActor
struct ControlFlowTests {
    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// The fixture log cut after its request line, an empty inbox, and the lines after the request for later.
    private func project(_ fixture: String) throws -> (dir: String, session: RequestStore.Session, rest: String) {
        let dir = NSTemporaryDirectory() + "gui-test-flow-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lines = try ConversationFixtures.lines(fixture)
        let cut = try #require(lines.firstIndex { $0.contains("control_request") })
        let out = dir + "/a.out.jsonl", inbox = dir + "/a.in.jsonl"
        FileManager.default.createFile(atPath: out, contents: Data((lines[...cut].joined(separator: "\n") + "\n").utf8))
        FileManager.default.createFile(atPath: inbox, contents: nil)
        let rest = lines[(cut + 1)...].joined(separator: "\n") + "\n"
        return (dir, .init(nodeKey: "a", outPath: out, inboxPath: inbox, live: true), rest)
    }

    private func decoded(_ text: String) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    private func run(_ fixture: String, inboxFixture: String, allow: Bool) async throws {
        let p = try project(fixture)
        defer { try? FileManager.default.removeItem(atPath: p.dir) }
        let store = RequestStore()
        store.setSessions([p.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        let cards = RequestCards(entries: [entry], card: store.card(for:), onAnswer: store.answer)
        cards.press(entry, allow: allow)
        try await wait { store.card(for: entry).outcome != nil }
        let written = try String(contentsOfFile: p.session.inboxPath, encoding: .utf8).split(separator: "\n")
        #expect(written.count == 1)
        let expectedLines = try ConversationFixtures.lines(inboxFixture)
        let expected = try #require(expectedLines.first { $0.contains("control_response") })
        #expect(try decoded(String(written[0])) == decoded(expected))
    }

    @Test func allowReachesTheInboxAsTheRecordedLine() async throws {
        try await run("can-use-tool-allow", inboxFixture: "can-use-tool-allow-inbox", allow: true)
    }

    @Test func denyReachesTheInboxAsTheRecordedLine() async throws {
        try await run("can-use-tool-deny", inboxFixture: "can-use-tool-deny-inbox", allow: false)
    }

    @Test func aStoreCreatedAfterTheToolResultShowsNoCard() async throws {
        let p = try project("can-use-tool-allow")
        defer { try? FileManager.default.removeItem(atPath: p.dir) }
        let first = RequestStore()
        first.setSessions([p.session])
        try await wait { first.entries.count == 1 }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: p.session.outPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(p.rest.utf8))
        try handle.close()
        let second = RequestStore()
        second.setSessions([p.session])
        try await wait { first.entries.isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(first.entries.isEmpty && second.entries.isEmpty)
    }

    private func questionStore(_ p: (dir: String, session: RequestStore.Session, rest: String)) async throws -> (RequestStore, RequestStore.Entry) {
        let store = RequestStore()
        store.setSessions([p.session])
        try await wait { store.entries.count == 1 }
        return (store, try #require(store.entries.first))
    }

    private func appendRest(_ p: (dir: String, session: RequestStore.Session, rest: String)) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: p.session.outPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(p.rest.utf8))
        try handle.close()
    }

    @Test func aQuestionReachesTheInboxAsTheRecordedLine() async throws {
        let p = try project("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: p.dir) }
        let (store, entry) = try await questionStore(p)
        let binding = QuestionBinding(store)
        #expect(binding.questions(entry).count == 2)
        let card = QuestionCard(entry: entry, state: store.card(for: entry), binding: binding, onDecline: { _ in })
        for (q, l) in [("Which color?", "Blue"), ("Which fruits?", "Apple"), ("Which fruits?", "Plum")] { card.pick(q, l) }
        card.send()
        try await wait { store.card(for: entry).outcome != nil }
        let written = try String(contentsOfFile: p.session.inboxPath, encoding: .utf8).split(separator: "\n")
        let expected = try #require(try ConversationFixtures.lines("ask-user-question-inbox").first { $0.contains("control_response") })
        #expect(written.count == 1)
        #expect(try decoded(String(written[0])) == decoded(expected))
    }

    @Test func theQuestionCardGoesWhenTheSessionContinuesAndALateStoreShowsNone() async throws {
        let p = try project("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: p.dir) }
        let (first, _) = try await questionStore(p)
        try appendRest(p)
        let second = RequestStore()
        second.setSessions([p.session])
        try await wait { first.entries.isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(first.entries.isEmpty && second.entries.isEmpty)
    }

    @Test func aGateHoldStaysWithTheHoldStoreAndNotTheRequestStore() async throws {
        let p = try project("can-use-tool-allow")
        let fx = try FixtureProject.make(withDatabase: false)
        let holdFiles = FixtureHolds(fx)
        defer {
            holdFiles.remove()
            try? FileManager.default.removeItem(atPath: p.dir)
        }
        try holdFiles.add(id: "toolu_H", label: "bravo")
        let holds = HoldStore()
        holds.point(at: fx.path)
        let requests = RequestStore()
        requests.setSessions([p.session])
        try await wait { holds.holds.count == 1 && requests.entries.count == 1 }
        #expect(holds.holds.map(\.label) == ["bravo"])
        #expect(requests.entries.map(\.nodeKey) == ["a"])
        #expect(requests.entries(for: "bravo").isEmpty)
    }

    private func twoNodes() throws -> (dir: String, a: RequestStore.Session, b: RequestStore.Session) {
        let dir = NSTemporaryDirectory() + "gui-test-ctlflow-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func session(_ name: String) -> RequestStore.Session {
            let out = dir + "/\(name).out.jsonl", inbox = dir + "/\(name).in.jsonl"
            FileManager.default.createFile(atPath: out, contents: nil)
            FileManager.default.createFile(atPath: inbox, contents: nil)
            return .init(nodeKey: name, outPath: out, inboxPath: inbox, live: true)
        }
        return (dir, session("a"), session("b"))
    }

    private func feed(_ fixture: String, into path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try ConversationFixtures.lines(fixture).joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    private func inboxLines(_ path: String) throws -> [Substring] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    }

    @Test func escAddsOneInterruptToItsOwnInboxAndTheEndedResultMovesTheState() async throws {
        let n = try twoNodes()
        defer { try? FileManager.default.removeItem(atPath: n.dir) }
        let store = RequestStore()
        store.setSessions([n.a, n.b])
        // The same two calls the prompt box's Esc closure makes.
        store.noteInterrupt(nodeKey: "a", id: "req-int-1")
        #expect(ControlLineWriter.appendInterrupt(id: "req-int-1", inbox: n.a.inboxPath) == .sent)
        let a = try inboxLines(n.a.inboxPath), b = try inboxLines(n.b.inboxPath)
        #expect(a.count == 1 && b.isEmpty)
        let sent = try decoded(String(try #require(a.first)))
        let recorded = try #require(ConversationFixtures.lines("interrupt-tool-inbox").first { $0.contains("control_request") })
        #expect(sent == (try decoded(recorded)))
        try feed("interrupt-tool", into: n.a.outPath)
        try await wait { store.control(for: "a").interrupt == .ended }
        #expect(store.control(for: "a").interrupt == .ended)
        #expect(store.control(for: "b").interrupt == nil)
    }

    @Test func theModelChoiceAddsSetModelAndTheLogMovesTheShownModel() async throws {
        let n = try twoNodes()
        defer { try? FileManager.default.removeItem(atPath: n.dir) }
        let store = RequestStore()
        store.setSessions([n.a, n.b])
        let picker = ControlPickerModel(
            currentModel: nil, currentEffort: nil,
            onModel: { _ = ControlLineWriter.appendSetModel($0, inbox: n.a.inboxPath) },
            onEffort: { _ = ControlLineWriter.appendEffort($0, inbox: n.a.inboxPath) })
        picker.pick(model: "sonnet")
        let written = try inboxLines(n.a.inboxPath)
        #expect(written.count == 1 && written[0].contains("set_model") && written[0].contains("sonnet"))
        #expect(try inboxLines(n.b.inboxPath).isEmpty)
        try feed("set-model", into: n.a.outPath)
        try await wait { store.control(for: "a").model == "claude-haiku-5-5" }
        #expect(store.control(for: "a").model == "claude-haiku-5-5")
        #expect(store.control(for: "b").model == nil)
    }

    @Test func theEffortChoiceAddsTheEffortUserLineToItsOwnInbox() throws {
        let n = try twoNodes()
        defer { try? FileManager.default.removeItem(atPath: n.dir) }
        let picker = ControlPickerModel(
            currentModel: nil, currentEffort: nil,
            onModel: { _ in }, onEffort: { _ = ControlLineWriter.appendEffort($0, inbox: n.a.inboxPath) })
        picker.pick(effort: "high")
        let written = try inboxLines(n.a.inboxPath)
        let expected = try #require(ConversationFixtures.lines("effort-inbox").first { $0.contains("/effort") })
        let sent = try decoded(String(written[0]))
        let recorded = try decoded(expected)
        #expect(written.count == 1 && sent == recorded)
        #expect(try inboxLines(n.b.inboxPath).isEmpty)
    }

    @Test func aWorkerLabelledHoldShowsNoRequestOrControlState() async throws {
        let n = try twoNodes()
        let fx = try FixtureProject.make(withDatabase: false)
        let holdFiles = FixtureHolds(fx)
        defer {
            holdFiles.remove()
            try? FileManager.default.removeItem(atPath: n.dir)
        }
        try holdFiles.add(id: "toolu_H", label: "bravo")
        let holds = HoldStore()
        holds.point(at: fx.path)
        let requests = RequestStore()
        requests.setSessions([n.a])
        try await wait { holds.holds.count == 1 }
        #expect(holds.holds.map(\.label) == ["bravo"])
        #expect(requests.entries(for: "bravo").isEmpty)
        #expect(requests.control(for: "bravo") == SessionControl())
    }
}
