import Foundation
import Testing
@testable import OrchestratorGUI

@MainActor
struct AnsweredQuestionsTests {
    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func make() async throws -> (dir: String, out: String, store: RequestStore, entry: RequestStore.Entry) {
        let dir = NSTemporaryDirectory() + "gui-test-answered-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = try #require(try ConversationFixtures.lines("ask-user-question").first { $0.contains("control_request") }) + "\n"
        let out = dir + "/a.out.jsonl", inbox = dir + "/a.in.jsonl"
        FileManager.default.createFile(atPath: out, contents: Data(log.utf8))
        FileManager.default.createFile(atPath: inbox, contents: nil)
        let store = RequestStore()
        store.setSessions([.init(nodeKey: "a", outPath: out, inboxPath: inbox, live: true)])
        try await wait { store.entries.count == 1 }
        return (dir, out, store, try #require(store.entries.first))
    }

    private func complete(_ s: (dir: String, out: String, store: RequestStore, entry: RequestStore.Entry), _ outcome: InboxDelivery.Outcome) {
        let result = RequestStore.attempt(request: s.entry.request, outPath: s.out) { outcome }
        s.store.completeSend(s.entry.key, nodeKey: "a", request: s.entry.request, picks: ["q": ["x"]], result)
    }

    @Test func aSentAnswerIsRecordedWithAllQuestions() async throws {
        let s = try await make()
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        complete(s, .sent)
        let rec = try #require(s.store.answered(for: "a").first)
        #expect(rec.questions == s.store.questions(for: s.entry))
        #expect(rec.questions.count >= 1)
        #expect(rec.picks == ["q": ["x"]])
        #expect(s.store.answered(for: "b").isEmpty)
    }

    @Test func aFailedSendRecordsNothing() async throws {
        let s = try await make()
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        complete(s, .failed("no"))
        complete(s, .refused("no"))
        #expect(s.store.answered(for: "a").isEmpty)
    }

    @Test func aDeclineRecordsNothing() async throws {
        let s = try await make()
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        s.store.answer(s.entry.key, allow: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(s.store.answered(for: "a").isEmpty)
    }

    @Test func recordSurvivesTheEntryBeingRemovedFirst() async throws {
        let s = try await make()
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let result = RequestStore.attempt(request: s.entry.request, outPath: s.out) { .sent }
        s.store.setSessions([])
        try await wait { s.store.entries.isEmpty }
        s.store.completeSend(s.entry.key, nodeKey: "a", request: s.entry.request, picks: [:], result)
        #expect(s.store.answered(for: "a").count == 1)
    }
}
