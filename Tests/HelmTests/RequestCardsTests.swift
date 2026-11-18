import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Helm

@MainActor
struct RequestCardsTests {
    private final class Calls {
        var answered: [String] = []
    }

    private let request = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"a":1},"tool_use_id":"t1"}}"#

    private func entry() throws -> RequestStore.Entry {
        var fold = ControlRequests()
        fold.feed(request)
        return RequestStore.Entry(key: "request:a:r1", nodeKey: "a", request: try #require(fold.pending.first), live: true)
    }

    @Test func pressesReachTheAnswerClosureWithTheKeyAndTheChoice() throws {
        let calls = Calls()
        let e = try entry()
        let cards = RequestCards(
            entries: [e],
            card: { RequestStore.Card(command: $0.request.text, stateLine: nil, outcome: nil, showsButtons: true, enabled: true) },
            onAnswer: { key, allow, _ in calls.answered.append("\(key) \(allow)") })
        cards.press(e, allow: true)
        cards.press(e, allow: false)
        #expect(calls.answered == ["request:a:r1 true", "request:a:r1 false"])
    }

    @Test func aDefaultBindingHasNoTypedAnswerAndTheStoreStepSetsIt() throws {
        #expect(QuestionBinding.none.onType == nil && QuestionBinding().onType == nil)
        let store = RequestStore()
        #expect(QuestionBinding(store).onType == nil)
        let bound = QuestionBinding(store).withTypedAnswers(store)
        #expect(bound.onType != nil)
        // An unknown key reaches the store and changes nothing.
        bound.onType?("nokey", "q", "text")
        #expect(store.picks(for: "nokey").isEmpty)
        let card = QuestionCard(entry: try entry(), state: RequestStore.Card(command: "", stateLine: nil, outcome: nil, showsButtons: true, enabled: true),
                                binding: bound, onDecline: { _ in })
        card.useTyped("q", "x")
    }

    @Test func theHighlightedButtonTitleCarriesAMarker() {
        #expect(RequestCards.title("Allow", highlighted: true) != RequestCards.title("Allow", highlighted: false))
        #expect(RequestCards.title("Deny", highlighted: false) == "Deny")
    }
}
