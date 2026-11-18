import Foundation
import Testing
@testable import Helm

private final class Texts: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return _all }
    func add(_ text: String) { lock.lock(); _all.append(text); lock.unlock() }
}

@MainActor
struct PromptBoxModelTests {
    private func model(_ texts: Texts, outcome: @escaping @Sendable () -> InboxDelivery.Outcome = { .sent },
                       delay: TimeInterval = 0) -> PromptBoxModel {
        PromptBoxModel { text in
            texts.add(text)
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return outcome()
        }
    }

    @Test func aSentOutcomeSetsSentAndNoMessage() async {
        let texts = Texts()
        let model = model(texts)
        await model.send("a\nb")
        #expect(texts.all == ["a\nb"])
        #expect(model.sent)
        #expect(model.message == nil)
    }

    @Test func refusedAndFailedSetTheMessageAndLeaveSentFalse() async {
        let refused = model(Texts(), outcome: { .refused("x") })
        await refused.send("hi")
        #expect(refused.message == "x")
        #expect(!refused.sent)
        let failed = model(Texts(), outcome: { .failed("y") })
        await failed.send("hi")
        #expect(failed.message == "y")
        #expect(!failed.sent)
    }

    @Test func twoRapidSendsCallTheClosureOnce() async {
        let texts = Texts()
        let model = model(texts, delay: 0.2)
        async let first: Void = model.send("one")
        async let second: Void = model.send("one")
        _ = await (first, second)
        #expect(texts.all.count == 1)
    }

    @Test func aNativeCommandOrANoteWritesNothingAndASendAppendsOneLine() async throws {
        let inbox = NSTemporaryDirectory() + "inbox-" + UUID().uuidString + ".jsonl"
        FileManager.default.createFile(atPath: inbox, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: inbox) }
        let model = ConversationHost.makeModel(inboxPath: inbox)
        let size = { (try? FileManager.default.attributesOfItem(atPath: inbox)[.size] as? Int) ?? -1 }
        await model.send("/mcp")
        #expect(size() == 0 && !model.sent && model.command == .mcp)
        await model.send("/vim")
        #expect(size() == 0 && model.message == "/vim is not available in headless sessions")
        await model.send("/agents")
        let lines = try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1 && model.sent)
    }

    @Test func aSendAfterAFailureClearsTheMessageFirst() async {
        let flag = Texts()
        let model = PromptBoxModel { text in
            flag.add(text)
            return flag.all.count == 1 ? .failed("boom") : .sent
        }
        await model.send("a")
        #expect(model.message == "boom")
        await model.send("a")
        #expect(model.message == nil)
        #expect(model.sent)
    }

    @Test func aDraftSurvivesASwitchAndASendClearsOnlyThatSessionsDraft() async {
        let store = RequestStore()
        let a = store.box(for: "A", inboxPath: nil), b = store.box(for: "B", inboxPath: nil)
        a.draft = "half typed"
        b.draft = "other"
        #expect(store.box(for: "A", inboxPath: nil).draft == "half typed")
        #expect(store.box(for: "B", inboxPath: nil).draft == "other")
        let sender = PromptBoxModel { _ in .sent }
        sender.draft = "hello"
        await sender.send("hello")
        #expect(sender.draft == "")
        #expect(store.box(for: "A", inboxPath: nil).draft == "half typed")
    }

    @Test func twoInboxPathsWithTheSameNodeKeyKeepSeparateDrafts() {
        let store = RequestStore()
        let a = store.box(for: "orchestrator", inboxPath: "/tmp/a/inbox.jsonl")
        let b = store.box(for: "orchestrator", inboxPath: "/tmp/b/inbox.jsonl")
        a.draft = "for a"
        #expect(b.draft == "")
        #expect(store.box(for: "orchestrator", inboxPath: "/tmp/a/inbox.jsonl") === a)
        #expect(store.box(for: "orchestrator", inboxPath: "/tmp/b/inbox.jsonl") === b)
    }

    @Test func aNativeCommandClearsTheDraftAndAFailedSendKeepsIt() async {
        let command = PromptBoxModel { _ in .sent }
        command.draft = "/mcp"
        await command.send("/mcp")
        #expect(command.draft == "")
        let failing = PromptBoxModel { _ in .failed("x") }
        failing.draft = "keep me"
        await failing.send("keep me")
        #expect(failing.draft == "keep me")
    }
}
