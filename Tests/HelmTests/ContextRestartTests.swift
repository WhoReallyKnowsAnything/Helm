import Foundation
import Testing
@testable import Helm

@MainActor
struct ContextRestartTests {
    @Test func aPendingQuestionReturnsAfterRestartAndNothingAnswersIt() async throws {
        let dir = NSTemporaryDirectory() + "gui-test-restart-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = try #require(try ConversationFixtures.lines("ask-user-question").first { $0.contains("control_request") }) + "\n"
        let out = dir + "/a.out.jsonl", inbox = dir + "/a.in.jsonl"
        FileManager.default.createFile(atPath: out, contents: Data(log.utf8))
        FileManager.default.createFile(atPath: inbox, contents: nil)

        let store = RequestStore()
        store.setSessions([.init(nodeKey: "cad-context-p3", outPath: out, inboxPath: inbox, live: true)])
        for _ in 0..<100 where store.entries.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }

        #expect(store.entries.count == 1)
        #expect(store.pendingQuestionLabels == ["cad-context-p3"])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(store.entries.count == 1)
        let sent = try String(contentsOfFile: inbox, encoding: .utf8)
        #expect(sent.isEmpty)
    }
}
