import Foundation
import Testing
@testable import Helm

/// Records what the stub delivery was asked to type, and where.
private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [(line: String, base: String)] = []
    func add(_ line: String, _ base: String) { lock.lock(); _items.append((line, base)); lock.unlock() }
    var items: [(line: String, base: String)] { lock.lock(); defer { lock.unlock() }; return _items }
}

@MainActor
struct PRMergeRequestTests {
    private func request(
        _ sent: Sent, outcome: InboxDelivery.Outcome = .sent, delay: TimeInterval = 0
    ) -> PRMergeRequest {
        PRMergeRequest { line, base in
            sent.add(line, base)
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return outcome
        }
    }

    @Test func theLineIsExactlyThePlannedText() {
        #expect(PRMergeRequest.line(number: 12, label: "fix-login", title: "Fix login")
            == "Please merge PR #12 of worker fix-login (task: Fix login)")
    }

    @Test func aTitleWithASemicolonAndANewlineArrivesAsOneCleanLine() throws {
        let line = try #require(PRMergeRequest.line(number: 3, label: "alpha", title: "Fix; login\nnow\u{1B}[31m"))
        #expect(line == "Please merge PR #3 of worker alpha (task: Fix; login now[31m)")
        #expect(!line.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
    }

    @Test(arguments: [nil, "", "   ", "\n\t"])
    func noUsableTitleGivesNoTaskText(title: String?) throws {
        let line = try #require(PRMergeRequest.line(number: 1, label: "alpha", title: title))
        #expect(line == "Please merge PR #1 of worker alpha")
        #expect(!line.contains("(task:"))
    }

    @Test(arguments: ["", "-x", "a b", "a\nb", "a;b", "../x"])
    func anInvalidLabelBuildsNoLine(label: String) {
        #expect(PRMergeRequest.line(number: 1, label: label, title: "t") == nil)
    }

    @Test func sendDeliversOneLineToTheBaseSession() async {
        let sent = Sent(), model = request(sent)
        await model.send(number: 12, label: "fix-login", title: "Fix login", base: "proj")
        #expect(sent.items.count == 1)
        #expect(sent.items.first?.line == "Please merge PR #12 of worker fix-login (task: Fix login)")
        #expect(sent.items.first?.base == "proj")
        #expect(model.state == .sent("Request sent: Please merge PR #12 of worker fix-login (task: Fix login)"))
    }

    @Test func twoRapidPressesDeliverOnce() async {
        let sent = Sent(), model = request(sent, delay: 0.2)
        async let first: Void = model.send(number: 1, label: "alpha", title: nil, base: "proj")
        async let second: Void = model.send(number: 1, label: "alpha", title: nil, base: "proj")
        _ = await (first, second)
        #expect(sent.items.count == 1)
    }

    @Test(arguments: [InboxDelivery.Outcome.refused("A permission dialog is showing"), .failed("tmux failed")])
    func aRefusedDeliveryPublishesItsText(outcome: InboxDelivery.Outcome) async {
        let sent = Sent(), model = request(sent, outcome: outcome)
        await model.send(number: 1, label: "alpha", title: nil, base: "proj")
        guard case .refused(let text) = model.state else { Issue.record("expected a refusal"); return }
        #expect(text.hasPrefix("Request not sent: "))
    }

    @Test func anInvalidLabelDeliversNothing() async {
        let sent = Sent(), model = request(sent)
        await model.send(number: 1, label: "-x", title: nil, base: "proj")
        #expect(sent.items.isEmpty)
        guard case .refused = model.state else { Issue.record("expected a refusal"); return }
    }

    @Test func resetClearsAResult() async {
        let sent = Sent(), model = request(sent)
        await model.send(number: 1, label: "alpha", title: nil, base: "proj")
        model.reset()
        #expect(model.state == .idle)
    }
}
