import Foundation
import SwiftUI
import Testing
@testable import Helm

/// The hold cards are one shared view: the tree and the terminal screen draw the same Approve and Deny, and both reach
/// `HoldStore.decide` through it (plan 12). What `decide` does is proved by the HoldStore click tests.
@MainActor
struct HoldCardsTests {
    private final class Calls {
        var decided: [String] = []
    }

    private static let hold = GateHold(id: "h1", label: "bravo", hash: String(repeating: "a", count: 64), epoch: 100, state: .live,
                                       command: "Bash: git push origin main")

    @Test func approveAndDenyCallOnDecideOnceEachWithTheHoldKeyAndTheChoice() {
        let calls = Calls()
        let cards = HoldCards(
            holds: [Self.hold],
            card: { HoldStore.Card(command: $0.command, stateLine: nil, outcome: nil, showsButtons: true, enabled: true) },
            onDecide: { key, choice in calls.decided.append("\(key) \(choice.rawValue)") })
        cards.press(Self.hold, .allow)
        #expect(calls.decided == ["\(Self.hold.key) allow"])
        cards.press(Self.hold, .deny)
        #expect(calls.decided == ["\(Self.hold.key) allow", "\(Self.hold.key) deny"])
    }

    /// One synchronous render of a card at the default node width, as PNG bytes, to compare two draws.
    private func cardPNG(onScreen: Bool) throws -> Data {
        let cards = HoldCards(
            holds: [Self.hold],
            card: { HoldStore.Card(command: $0.command, stateLine: nil, outcome: nil, showsButtons: true, enabled: true) },
            onDecide: { _, _ in }, onScreen: onScreen)
        let size = TreeLayout.nodeSize
        let rep = try RenderSupport.render(cards.frame(width: size.width), .content(width: size.width))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func aCardThatIsNotOnScreenDrawsApproveDimmed() throws {
        #expect(try cardPNG(onScreen: false) != cardPNG(onScreen: true))
    }

    @Test func anEnabledCardOnScreenDrawsTheSameTwice() throws {
        #expect(try cardPNG(onScreen: true) == cardPNG(onScreen: true))
    }

    /// Source scan, in the style of `NoApprovePathTests`: one view builds the buttons and calls `onDecide`.
    private func source(_ name: String) throws -> String {
        try String(contentsOfFile: ApprovePathScan.sources + "/" + name, encoding: .utf8)
    }

    private func count(_ token: String, in text: String) -> Int { text.components(separatedBy: token).count - 1 }

    @Test func onlyHoldCardsCallsOnDecide() throws {
        let walker = try #require(FileManager.default.enumerator(atPath: ApprovePathScan.sources))
        var files: [String] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            if try String(contentsOfFile: ApprovePathScan.sources + "/" + relative, encoding: .utf8).contains("onDecide(") {
                files.append((relative as NSString).lastPathComponent)
            }
        }
        #expect(files == ["HoldCards.swift"])
    }

    @Test func theTreeAndTheTerminalUseTheSharedViewAndBuildNoDecisionButton() throws {
        for name in ["WorkerTreeView.swift", "ProjectHoldBar.swift"] {
            let text = try source(name)
            #expect(text.contains("HoldCards"), "\(name) does not use the shared view")
            for token in ["\"Approve\"", "\"Deny\"", ", .allow", ", .deny"] {
                #expect(!text.contains(token), "\(name) builds a decision button itself: \(token)")
            }
        }
    }

    @Test func contentViewPassesHoldsDecideWhereItBuildsTheTreeAndTheTerminalOnly() throws {
        let content = try source("ContentView.swift")
        #expect(count("onDecide: holds.decide", in: content) == 2)
        #expect(count("holds.decide", in: content) == 2)
        #expect(count("HoldCards(", in: content) == 0)
        let walker = try #require(FileManager.default.enumerator(atPath: ApprovePathScan.sources))
        for case let relative as String in walker where relative.hasSuffix(".swift") && !relative.hasSuffix("ContentView.swift") {
            let text = try String(contentsOfFile: ApprovePathScan.sources + "/" + relative, encoding: .utf8)
            #expect(!text.contains("holds.decide"), "\(relative) reaches HoldStore.decide")
        }
    }
}
