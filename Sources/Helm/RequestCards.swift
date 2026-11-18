import SwiftUI

/// The permission cards of one node (D-02). Same card, text and button parts as `HoldCards`, but its own view (D-05).
/// This is the only caller of the request store's `answer`.
struct RequestCards: View {
    let entries: [RequestStore.Entry]
    let card: (RequestStore.Entry) -> RequestStore.Card
    let onAnswer: (_ key: String, _ allow: Bool, _ source: RequestStore.DenySource) -> Void
    /// False when the cards are clipped by the canvas or covered by other cards: then Allow stays disabled.
    var onScreen = true
    /// The question side of the store. With the default, no request is a question and every card is the allow/deny card.
    var question = QuestionBinding.none
    /// `RequestStore.stamp`. A changed value makes SwiftUI run the body again.
    var stamp = 0
    /// Called for Escape on a focused card (D-08): the bar passes the node's interrupt, the tree passes nil.
    var onEscape: (() -> Void)?

    /// What a click on Allow or Deny does. A test calls it without a click.
    func press(_ entry: RequestStore.Entry, allow: Bool) { onAnswer(entry.key, allow, .denyButton) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(entries) { entry in
                let state = card(entry)
                if question.questions(entry).isEmpty {
                    permissionCard(entry, state)
                } else {
                    QuestionCard(entry: entry, state: state, binding: question,
                                 onDecline: { key in
                                    if let confirm = question.onDecline { confirm(key) } else { onAnswer(key, false, .declineButton) }
                                 }, onScreen: onScreen, onEscape: onEscape, stamp: stamp)
                }
            }
        }
    }

    private func permissionCard(_ entry: RequestStore.Entry, _ state: RequestStore.Card) -> some View {
        let high = question.highlight(entry.key)
        return KitHoldCard(stateLine: state.stateLine, outcome: state.outcome) {
            HoldCommandText(text: state.command)
        } decision: {
            if state.showsButtons {
                KitButtonPair {
                    answerButton(Self.title("Allow", highlighted: high == 0), allow: true, entry: entry, enabled: state.enabled && onScreen)
                    answerButton(Self.title("Deny", highlighted: high == 1), allow: false, entry: entry, enabled: state.enabled)
                }
            }
        }
        .modifier(CardKeys(key: entry.key, binding: question, onEscape: onEscape))
    }

    /// The highlighted button carries a marker in its text, as an option row does.
    static func title(_ name: String, highlighted: Bool) -> String { highlighted ? "> \(name)" : name }

    /// Built from the key it is drawn with. Keys reach the store through `CardKeys`; a click answers as before.
    private func answerButton(_ title: String, allow: Bool, entry: RequestStore.Entry, enabled: Bool) -> some View {
        Button { press(entry, allow: allow) } label: { Text(title) }
            .buttonStyle(.kit)
            .disabled(!enabled)
            .accessibilityLabel("\(allow ? "Allow" : "Deny") \(entry.request.toolName)")
    }
}
