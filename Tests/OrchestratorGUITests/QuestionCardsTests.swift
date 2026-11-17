import Foundation
import SwiftUI
import Testing
@testable import OrchestratorGUI

@MainActor
struct QuestionCardsTests {
    private func session() throws -> (dir: String, session: RequestStore.Session) {
        let dir = NSTemporaryDirectory() + "gui-test-qc-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lines = try ConversationFixtures.lines("ask-user-question")
        let log = try #require(lines.first { $0.contains("control_request") }) + "\n"
        let out = dir + "/a.out.jsonl", inbox = dir + "/a.in.jsonl"
        FileManager.default.createFile(atPath: out, contents: Data(log.utf8))
        FileManager.default.createFile(atPath: inbox, contents: nil)
        return (dir, .init(nodeKey: "a", outPath: out, inboxPath: inbox, live: true))
    }

    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func picksThenSendThroughTheSeamWriteTheRecordedLine() async throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let store = RequestStore()
        store.setSessions([s.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        let card = QuestionCard(entry: entry, state: store.card(for: entry), binding: QuestionBinding(store), onDecline: { _ in })
        card.send()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try String(contentsOfFile: s.session.inboxPath, encoding: .utf8).isEmpty)
        for (q, l) in [("Which color?", "Blue"), ("Which fruits?", "Apple"), ("Which fruits?", "Plum")] { card.pick(q, l) }
        card.send()
        try await wait { store.card(for: entry).outcome != nil }
        let written = try String(contentsOfFile: s.session.inboxPath, encoding: .utf8).split(separator: "\n")
        let expected = try #require(try ConversationFixtures.lines("ask-user-question-inbox").first { $0.contains("control_response") })
        #expect(written.count == 1)
        #expect(try JSONSerialization.jsonObject(with: Data(written[0].utf8)) as? NSDictionary
                == (try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary))
    }

    @Test func declineGoesThroughTheDenyClosure() throws {
        var declined: [String] = []
        let entry = RequestStore.Entry(key: "k", nodeKey: "a", request: try request(tool: "AskUserQuestion", input: questions), live: true)
        let card = QuestionCard(entry: entry, state: .init(command: "", stateLine: nil, outcome: nil, showsButtons: true, enabled: true),
                                binding: .none, onDecline: { declined.append($0) })
        card.decline()
        #expect(declined == ["k"])
    }

    @Test func otherToolsAndUnparsableQuestionsAreNotQuestions() throws {
        let store = RequestStore()
        for (tool, input) in [("ExitPlanMode", questions), ("AskUserQuestion", #"{"questions":[]}"#)] {
            let entry = RequestStore.Entry(key: "k", nodeKey: "a", request: try request(tool: tool, input: input), live: true)
            #expect(store.questions(for: entry).isEmpty)
        }
    }

    @Test func aQuestionBindingRoutesOnlyAskUserQuestionToTheQuestionCard() throws {
        let binding = QuestionBinding(RequestStore())
        let cases = [("AskUserQuestion", questions, true), ("ExitPlanMode", questions, false),
                     ("Bash", #"{"a":1}"#, false), ("AskUserQuestion", #"{"questions":[]}"#, false)]
        for (tool, input, isQuestion) in cases {
            let e = RequestStore.Entry(key: "k", nodeKey: "a", request: try request(tool: tool, input: input), live: true)
            #expect(binding.questions(e).isEmpty != isQuestion)
        }
    }

    @Test func aLongOptionDescriptionIsPresentInFull() {
        let long = String(repeating: "word ", count: 200)
        let text = QuestionCard.optionText(.init(label: "A", description: long), selected: true)
        #expect(text.hasPrefix("[x] A - ") && text.hasSuffix(long))
    }

    private let questions = #"{"questions":[{"question":"Q","options":[{"label":"A","description":"d"}]}]}"#

    private func request(tool: String, input: String) throws -> PermissionRequest {
        var fold = ControlRequests()
        fold.feed(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"\#(tool)","input":\#(input),"tool_use_id":"t1"}}"#)
        return try #require(fold.pending.first)
    }

    /// One synchronous render of an AskUserQuestion card with `optionCount` options and the typed field on.
    private func cardPNG(optionCount: Int, state: RequestStore.Card) throws -> Data {
        let entry = RequestStore.Entry(key: "k", nodeKey: "a", request: try request(tool: "AskUserQuestion", input: questions), live: true)
        let options = (0..<optionCount).map { QuestionInput.Option(label: "Option \($0)", description: "d") }
        var binding = QuestionBinding()
        binding.questions = { _ in [QuestionInput.Question(text: "Q", header: nil, options: options, multiSelect: false)] }
        binding.onType = { _, _, _ in }
        let card = QuestionCard(entry: entry, state: state, binding: binding, onDecline: { _ in })
        let rep = try RenderSupport.render(card.frame(width: 400), .content(width: 400))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func aCardThatIsNotLiveDrawsNoOptionRowsAndNoTypedField() throws {
        let ended = RequestStore.Card(command: "", stateLine: "worker ended", outcome: nil, showsButtons: false, enabled: false)
        let live = RequestStore.Card(command: "", stateLine: nil, outcome: nil, showsButtons: true, enabled: true)
        #expect(try cardPNG(optionCount: 3, state: ended) == cardPNG(optionCount: 0, state: ended))
        #expect(try cardPNG(optionCount: 3, state: live) != cardPNG(optionCount: 0, state: live))
    }

    @Test func theHighlightedOptionCarriesADifferentMarker() {
        let option = QuestionInput.Option(label: "A", description: "")
        #expect(QuestionCard.optionText(option, selected: false, highlighted: true)
                != QuestionCard.optionText(option, selected: false))
    }

    private final class Recorder { var keys: [RequestStore.KeyPress] = []; var escapes = 0 }

    @Test func aCardRoutesArrowsReturnAndDigitsButNotLettersAndEscapeGoesToOnEscape() {
        let rec = Recorder()
        var binding = QuestionBinding()
        binding.onKey = { _, press in rec.keys.append(press); return press.key != .other }
        typealias K = RequestStore.KeyPress
        func route(_ p: K, escape: Bool = false, onEscape: (() -> Void)? = nil) -> Bool {
            CardKeys.route(p, isEscape: escape, key: "k", binding: binding, onEscape: onEscape)
        }
        for key in [K.Key.up, .down, .enter, .digit(2)] { #expect(route(K(key: key))) }
        #expect(!route(K(key: .other)))
        #expect(!route(K(key: .other), escape: true))
        #expect(route(K(key: .other), escape: true, onEscape: { rec.escapes += 1 }))
        #expect(rec.escapes == 1)
        #expect(rec.keys.count == 5)
    }

    @Test func escapeOnAFocusedCardWritesOneInterruptLineToItsNode() async throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let store = RequestStore()
        store.setSessions([s.session])
        try await wait { store.entries.count == 1 }
        let entry = try #require(store.entries.first)
        let binding = QuestionBinding(store)
        #expect(CardKeys.route(.init(key: .other), isEscape: true, key: entry.key, binding: binding,
                               onEscape: { store.interrupt(nodeKey: s.session.nodeKey) }))
        try await wait { ((try? String(contentsOfFile: s.session.inboxPath, encoding: .utf8)) ?? "").contains("interrupt") }
        let written = try String(contentsOfFile: s.session.inboxPath, encoding: .utf8).split(separator: "\n")
        #expect(written.count == 1)
        let line = try #require(try JSONSerialization.jsonObject(with: Data(written[0].utf8)) as? [String: Any])
        #expect((line["request"] as? [String: Any])?["subtype"] as? String == "interrupt")
    }
}
