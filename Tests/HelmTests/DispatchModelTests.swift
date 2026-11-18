import Foundation
import Testing
@testable import Helm

/// Records what a stub delivery was asked to type.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return _all }
    func add(_ line: String) { lock.lock(); _all.append(line); lock.unlock() }
}

@MainActor
struct DispatchModelTests {
    private func model(_ lines: Lines, outcome: InboxDelivery.Outcome = .sent, delay: TimeInterval = 0) -> DispatchModel {
        DispatchModel { line in
            lines.add(line)
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return outcome
        }
    }

    @Test func aPickDeliversTheExactLineOnce() async {
        let lines = Lines()
        let model = model(lines)
        await model.pick(title: "Fix login")
        #expect(lines.all == ["Pick up the Notion task: Fix login"])
        #expect(model.sent)
        #expect(model.message == nil)
    }

    @Test func aTitleWithANewlineAndASemicolonIsOneLine() async {
        let lines = Lines()
        let model = model(lines)
        await model.pick(title: "Fix\nlogin; now")
        #expect(lines.all == ["Pick up the Notion task: Fix login; now"])
    }

    @Test func twoQuickPicksDeliverOnce() async {
        let lines = Lines()
        let model = model(lines, delay: 0.2)
        async let first: Void = model.pick(title: "One")
        async let second: Void = model.pick(title: "One")
        _ = await (first, second)
        #expect(lines.all.count == 1)
    }

    @Test func aTitleThatCleansToNothingDeliversNothing() async {
        let lines = Lines()
        let model = model(lines)
        await model.pick(title: " \n\u{1B} ")
        #expect(lines.all.isEmpty)
        #expect(model.message != nil)
        #expect(!model.sent)
    }

    // MARK: the Dispatch bar

    /// Counts how often the bar asked to open the sheet.
    private final class Opens { var count = 0 }

    @Test func theBarTextReachesTheSameDeliveryAsAPickWithoutAPrefix() async {
        let lines = Lines()
        let model = model(lines)
        await model.pick(title: "A")
        await model.sendRequest("B fix") {}
        #expect(lines.all == ["Pick up the Notion task: A", "B fix"])
    }

    @Test func aNewlineAndATabInTheBarTextBecomeSingleSpaces() async {
        let lines = Lines()
        await model(lines).sendRequest("add\nthe\texport") {}
        #expect(lines.all == ["add the export"])
    }

    @Test(arguments: ["", " \n\t "])
    func emptyBarTextOpensTheSheetAndClearsAnOldRefusal(text: String) async {
        let lines = Lines(), opens = Opens()
        let model = model(lines, outcome: .refused("A dialog is open."))
        await model.pick(title: "One")
        #expect(model.message != nil)
        await model.sendRequest(text) { opens.count += 1 }
        #expect(lines.all == ["Pick up the Notion task: One"])
        #expect(opens.count == 1)
        #expect(model.message == nil)
        #expect(!model.sent)
    }

    @Test func barTextDoesNotOpenTheSheetAndIsSent() async {
        let opens = Opens()
        let model = model(Lines())
        await model.sendRequest("add the export") { opens.count += 1 }
        #expect(opens.count == 0)
        #expect(model.sent)
    }

    @Test func barTextThatCleansToNothingSendsNothingAndKeepsTheSheetClosed() async {
        let lines = Lines(), opens = Opens()
        let model = model(lines)
        await model.sendRequest("\u{1B}") { opens.count += 1 }
        #expect(lines.all.isEmpty && opens.count == 0)
        #expect(model.message != nil)
        #expect(!model.sent)
    }

    @Test(arguments: [InboxDelivery.Outcome.refused("A dialog is open."), .failed("No window.")])
    func aRefusedOrFailedBarSendShowsItsTextAndIsNotSent(outcome: InboxDelivery.Outcome) async {
        let model = model(Lines(), outcome: outcome)
        await model.sendRequest("One") {}
        #expect(!model.sent)
        switch outcome {
        case .refused(let text), .failed(let text): #expect(model.message == text)
        case .sent: Issue.record("unexpected")
        }
    }

    @Test func barTextOverTheLimitIsRefusedNotCut() async {
        let cap = InboxDelivery.requestMaxLength
        let crlf = String(repeating: "a", count: cap - 1) + "\r\n"
        #expect(crlf.count == cap && crlf.unicodeScalars.count == cap + 1)
        for text in [String(repeating: "a", count: cap + 1), crlf] {
            let lines = Lines(), opens = Opens()
            let model = model(lines)
            await model.sendRequest(text) { opens.count += 1 }
            #expect(lines.all.isEmpty && opens.count == 0)
            #expect(!model.sent)
            #expect(model.message == "Too long to send: \(cap + 1) of \(cap) characters")
        }
        let lines = Lines()
        let exact = String(repeating: "a", count: cap)
        let model = model(lines)
        await model.sendRequest(exact) {}
        #expect(lines.all == [exact] && model.sent)
    }

    @Test func aLongBarRequestWithBreaksArrivesAsOneLineOfTheSameLength() async throws {
        let lines = Lines()
        let model = model(lines)
        let text = String(repeating: "ab\r\ncd\nef ", count: 150)
        await model.sendRequest(text) {}
        let line = try #require(lines.all.first)
        #expect(lines.all.count == 1 && model.sent)
        #expect(line == text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
        #expect(line.unicodeScalars.count == text.unicodeScalars.count)
        #expect(line.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
    }

    @Test func aLongPickTitleIsStillCutAtTheBoardCap() async {
        let lines = Lines()
        let model = model(lines)
        await model.pick(title: String(repeating: "t", count: 350))
        #expect(lines.all == [DispatchModel.linePrefix + String(repeating: "t", count: InboxDelivery.maxLength)])
        #expect(model.sent)
    }

    @Test(arguments: [InboxDelivery.Outcome.refused("A dialog is open."), .failed("No window.")])
    func aRefusedOrFailedDeliveryShowsItsTextAndIsNotSent(outcome: InboxDelivery.Outcome) async {
        let model = model(Lines(), outcome: outcome)
        await model.pick(title: "One")
        #expect(!model.sent)
        switch outcome {
        case .refused(let text), .failed(let text): #expect(model.message == text)
        case .sent: Issue.record("unexpected")
        }
    }

    @Test func aBuiltLineIsDeliveredOnceAndSentTurnsTrue() async {
        let lines = Lines()
        let model = model(lines)
        await model.sendLine("Cadence stage: skill=/cadence:cad-execute phase=1 model=none effort=none")
        #expect(lines.all == ["Cadence stage: skill=/cadence:cad-execute phase=1 model=none effort=none"])
        #expect(model.sent)
    }

    @Test func twoQuickLineSendsDeliverOnce() async {
        let lines = Lines()
        let model = model(lines, delay: 0.2)
        async let first: Void = model.sendLine("One")
        async let second: Void = model.sendLine("One")
        _ = await (first, second)
        #expect(lines.all.count == 1)
    }

    @Test func aLineOver2000ScalarsIsRefusedAndNothingIsDelivered() async {
        let lines = Lines()
        let model = model(lines)
        await model.sendLine(String(repeating: "t", count: InboxDelivery.requestMaxLength + 1))
        #expect(lines.all.isEmpty)
        #expect(!model.sent)
        #expect(model.message != nil)
    }
}
