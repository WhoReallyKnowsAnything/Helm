import Foundation
import Testing
@testable import OrchestratorGUI

@MainActor
struct RequestStoreTests {
    private let request = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"a":1},"tool_use_id":"t1","decision_reason":"why"}}"#
    private let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#

    private struct Node {
        let session: RequestStore.Session
        var inbox: String { session.inboxPath }
    }

    private func folder() throws -> String {
        let path = NSTemporaryDirectory() + "gui-test-req-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func node(_ dir: String, _ name: String, log: String = "", live: Bool = true) -> Node {
        let out = dir + "/\(name).out.jsonl", inbox = dir + "/\(name).in.jsonl"
        FileManager.default.createFile(atPath: out, contents: Data(log.utf8))
        FileManager.default.createFile(atPath: inbox, contents: nil)
        return Node(session: .init(nodeKey: name, outPath: out, inboxPath: inbox, live: live))
    }

    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func lines(_ path: String) throws -> [Substring] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    }

    @Test func allowIsEnabledAtOnceAndWritesToItsOwnInboxOnly() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: request + "\n"), b = node(dir, "b")
        let store = RequestStore()
        store.setSessions([a.session, b.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        #expect(entry.key == "request:a:r1")
        #expect(store.card(for: entry).command.hasPrefix("Bash "))
        #expect(store.card(for: entry).stateLine == "why")

        #expect(store.card(for: entry).enabled)
        store.answer(entry.key, allow: true)
        try await wait { store.card(for: entry).outcome != nil }
        #expect(store.card(for: entry).outcome == "decision sent")
        #expect(!store.card(for: entry).showsButtons)
        #expect(try lines(a.inbox).count == 1)
        #expect(try lines(b.inbox).isEmpty)
    }

    @Test func denyWritesAtOnceWithoutTheShownReport() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: request + "\n")
        let store = RequestStore()
        store.setSessions([a.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        store.answer(entry.key, allow: false)
        try await wait { store.card(for: entry).outcome != nil }
        let written = try lines(a.inbox)
        #expect(written.count == 1 && written[0].contains(#""behavior":"deny""#))
    }

    @Test func aRequestAnsweredElsewhereBetweenDrawAndPressWritesNothing() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: request + "\n")
        var fold = ControlRequests()
        fold.feed(request)
        let drawn = try #require(fold.pending.first)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: a.session.outPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((toolResult + "\n").utf8))
        try handle.close()
        let result = RequestStore.attempt(request: drawn, allow: true, outPath: a.session.outPath, inbox: a.inbox)
        #expect(result.text == "already decided or ended" && result.final)
        #expect(try lines(a.inbox).isEmpty)
    }

    @Test func aDeadSessionShowsNoButtons() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: request + "\n", live: false)
        let store = RequestStore()
        store.setSessions([a.session])
        try await wait { store.entries.count == 1 }
        let card = store.card(for: try #require(store.entries.first))
        #expect(!card.showsButtons && !card.enabled)
        #expect(card.stateLine == "session ended")
    }

    private func questionLog() throws -> String {
        let lines = try ConversationFixtures.lines("ask-user-question")
        return try #require(lines.first { $0.contains("control_request") }) + "\n"
    }

    private let color = "Which color?", fruits = "Which fruits?"

    @Test func sendWaitsForEveryPickThenWritesOneLineToItsOwnInboxOnly() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: try questionLog()), b = node(dir, "b")
        let store = RequestStore()
        store.setSessions([a.session, b.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        #expect(!store.canSend(entry))
        store.pick(entry.key, question: color, label: "Red")
        store.pick(entry.key, question: color, label: "Blue")
        #expect(store.picks(for: entry.key)[color] == ["Blue"])
        store.send(entry.key)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try lines(a.inbox).isEmpty)
        store.pick(entry.key, question: fruits, label: "Apple")
        store.pick(entry.key, question: fruits, label: "Pear")
        store.pick(entry.key, question: fruits, label: "Pear")
        store.pick(entry.key, question: fruits, label: "Plum")
        #expect(store.picks(for: entry.key)[fruits] == ["Apple", "Plum"])
        #expect(store.canSend(entry))
        store.send(entry.key)
        try await wait { store.card(for: entry).outcome != nil }
        #expect(store.card(for: entry).outcome == "decision sent")
        #expect(try lines(a.inbox).count == 1)
        #expect(try lines(b.inbox).isEmpty)
        let expected = try #require(try ConversationFixtures.lines("ask-user-question-inbox").first { $0.contains("control_response") })
        let written = try JSONSerialization.jsonObject(with: Data(try lines(a.inbox)[0].utf8)) as? NSDictionary
        #expect(written == (try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary))
    }

    @Test func aTypedAnswerSendsItsExactTextToItsOwnInboxOnly() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: try questionLog()), b = node(dir, "b")
        let store = RequestStore()
        store.setSessions([a.session, b.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        let typed = "say \"hi\" \\ back\nsecond line"
        store.typeAnswer(entry.key, question: color, text: "  \(typed)\n ")
        store.typeAnswer(entry.key, question: fruits, text: "Apple")
        #expect(store.picks(for: entry.key)[color] == [typed] && store.canSend(entry))
        store.send(entry.key)
        try await wait { store.card(for: entry).outcome != nil }
        #expect(try lines(a.inbox).count == 1 && (try lines(b.inbox).isEmpty))
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(try lines(a.inbox)[0].utf8)) as? [String: Any])
        let inner = try #require((sent["response"] as? [String: Any])?["response"] as? [String: Any])
        let answers = try #require((inner["updatedInput"] as? [String: Any])?["answers"] as? [String: String])
        #expect(answers[color] == typed)
    }

    @Test func emptyOrUnknownTypedTextChangesNothingAndALabelPickReplacesIt() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: try questionLog())
        let store = RequestStore()
        store.setSessions([a.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        store.typeAnswer(entry.key, question: color, text: "")
        store.typeAnswer(entry.key, question: color, text: " \n\t ")
        store.typeAnswer(entry.key, question: "No such question", text: "x")
        store.typeAnswer("no-such-key", question: color, text: "x")
        #expect(store.picks(for: entry.key).isEmpty)
        store.typeAnswer(entry.key, question: color, text: "mine")
        store.typeAnswer(entry.key, question: color, text: "second")
        #expect(store.picks(for: entry.key)[color] == ["second"])
        store.pick(entry.key, question: color, label: "Red")
        #expect(store.picks(for: entry.key)[color] == ["Red"])
    }

    @Test func aQuestionAnsweredElsewhereBetweenDrawAndPressWritesNothing() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: try questionLog())
        var fold = ControlRequests()
        fold.feed(try questionLog())
        let drawn = try #require(fold.pending.first)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: a.session.outPath))
        try handle.seekToEnd()
        let done = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":""# + drawn.toolUseId + #"","content":"ok"}]}}"# + "\n"
        try handle.write(contentsOf: Data(done.utf8))
        try handle.close()
        let result = RequestStore.attempt(request: drawn, outPath: a.session.outPath) {
            ControlAnswerWriter.appendAnswers(drawn, picks: [:], inbox: a.inbox)
        }
        #expect(result.text == "already decided or ended" && result.final)
        #expect(try lines(a.inbox).isEmpty)
    }

    @Test func declineWritesTheDenyLineAndANonQuestionToolHasNoQuestions() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: try questionLog())
        let store = RequestStore()
        store.setSessions([a.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        store.answer(entry.key, allow: false)
        try await wait { store.card(for: entry).outcome != nil }
        let written = try lines(a.inbox)
        #expect(written.count == 1 && written[0].contains(#""behavior":"deny""#))
        var fold = ControlRequests()
        fold.feed(request)
        let other = RequestStore.Entry(key: "k", nodeKey: "a", request: try #require(fold.pending.first), live: true)
        #expect(store.questions(for: other).isEmpty)
    }

    private final class Lines { var all: [String] = [] }

    @Test func oneDeclineClickWritesAndLogsNothingAndTheConfirmDeniesOnce() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: try questionLog())
        let store = RequestStore(), log = Lines()
        store.denyLog = { log.all.append($0) }
        store.setSessions([a.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        store.declineClicked(entry.key)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.isDeclineArmed(entry.key))
        #expect(log.all.isEmpty)
        #expect(try lines(a.inbox).isEmpty)
        store.declineClicked(entry.key)
        try await wait { store.card(for: entry).outcome != nil }
        #expect(log.all.count == 1)
        #expect(log.all[0].contains("request=\(entry.request.requestId)") && log.all[0].contains("session=a")
                && log.all[0].contains("source=declineButton"))
        #expect(try lines(a.inbox).count == 1)
        #expect(!store.isDeclineArmed(entry.key))
    }

    @Test func eachDenyPathPassesItsSourceAndAllowLogsNothing() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: request + "\n")
        let store = RequestStore(), log = Lines()
        store.denyLog = { log.all.append($0) }
        store.setSessions([a.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)

        // Deny button
        let cards = RequestCards(entries: [entry], card: store.card(for:), onAnswer: store.answer)
        cards.press(entry, allow: false)
        try await wait { store.card(for: entry).outcome != nil }
        #expect(log.all.count == 1 && log.all[0].contains("source=denyButton"))

        // Return on row 1 (Deny)
        let b = node(dir, "b", log: request + "\n")
        store.setSessions([a.session, b.session])
        try await wait { store.entries.contains { $0.nodeKey == "b" } }
        let second = try #require(store.entries.first { $0.nodeKey == "b" })
        _ = store.handle(.init(key: .digit(2)), for: second.key)
        _ = store.handle(.init(key: .enter), for: second.key)
        try await wait { store.card(for: second).outcome != nil }
        #expect(log.all.count == 2 && log.all[1].contains("source=returnKey"))

        // Allow logs nothing
        let c = node(dir, "c", log: request + "\n")
        store.setSessions([a.session, b.session, c.session])
        try await wait { store.entries.contains { $0.nodeKey == "c" } }
        let third = try #require(store.entries.first { $0.nodeKey == "c" })
        store.answer(third.key, allow: true, source: .other)
        try await wait { store.card(for: third).outcome != nil }
        #expect(log.all.count == 2)
    }

    @Test func eachNodeKeepsItsOwnModelAndInterruptState() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let init1 = #"{"type":"system","subtype":"init","model":"claude-haiku-5-5"}"# + "\n"
        let a = node(dir, "a", log: init1)
        let b = node(dir, "b", log: "")
        let store = RequestStore()
        store.setSessions([a.session, b.session])
        try await wait { store.control(for: "a").model != nil }
        #expect(store.control(for: "a").model == "claude-haiku-5-5")
        #expect(store.control(for: "b").model == nil)
        store.noteInterrupt(nodeKey: "a", id: "x")
        try await wait { store.control(for: "a").interrupt == .sending }
        #expect(store.control(for: "a").interrupt == .sending)
        #expect(store.control(for: "b").interrupt == nil)
    }

    @Test func aRequestNeverExpires() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = node(dir, "a", log: request + "\n")
        let store = RequestStore()
        store.setSessions([a.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(store.entries.count == 1)
        #expect(store.card(for: entry).showsButtons && store.card(for: entry).enabled)
    }
}
