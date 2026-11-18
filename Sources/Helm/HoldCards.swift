import SwiftUI

/// The gate hold cards of one worker. The tree draws it under the node and the terminal screen draws it above the pane.
/// This is the only view that builds Approve and Deny and the only place that calls `onDecide`, so both surfaces share one decide path.
struct HoldCards: View {
    let holds: [GateHold]
    /// What a hold card shows and whether its buttons work, and the answer to a click. Both come from the hold store (D-06).
    let card: (GateHold) -> HoldStore.Card
    let onDecide: (_ key: String, _ choice: HoldChoice) -> Void
    /// False when the cards are clipped by the canvas or covered by other cards: then Approve stays disabled. The terminal
    /// draws the cards in the normal screen flow, so it leaves this at true.
    var onScreen = true

    /// What a click on Approve or Deny does. A test calls it without a click.
    func press(_ hold: GateHold, _ choice: HoldChoice) { onDecide(hold.key, choice) }

    /// Oldest hold first (D-13). The hold key is the identity, so a card keeps its place when another one goes.
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(holds, id: \.key) { hold in
                let state = card(hold)
                KitHoldCard(stateLine: state.stateLine, outcome: state.outcome) {
                    HoldCommandText(text: state.command)
                } decision: {
                    if state.showsButtons {
                        // The pair sits side by side when the card is wide enough, else stacked. A label never wraps.
                        KitButtonPair {
                            decideButton("Approve", .allow, hold: hold, enabled: state.enabled && onScreen)
                            decideButton("Deny", .deny, hold: hold, enabled: state.enabled)
                        }
                    }
                }
            }
        }
    }

    /// Built from the hold key it is drawn with (D-06). No keyboard shortcut and no default action: with several holds
    /// on screen a shortcut could fire on the wrong one. Focus and the space key are the keyboard path.
    private func decideButton(_ title: String, _ choice: HoldChoice, hold: GateHold, enabled: Bool) -> some View {
        Button { press(hold, choice) } label: { Text(title) }
            .buttonStyle(.kit)
            .disabled(!enabled)
            .accessibilityLabel("\(title) \(hold.label): \(hold.command.prefix(60))")
    }
}

/// The op text of one hold card (D-06). It is cut at `Metric.opTextLines` lines until "Show all" is pressed. The card measures the cut text
/// against the whole text to decide whether the button shows.
struct HoldCommandText: View {
    let text: String
    @State private var expanded = false
    @State private var cutHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    /// The expanded text's frame in the scroll box's space, so the box follows the text height.
    @State private var content: CGRect = .zero

    private static let font = KitType.meta.font
    private static let space = "opScroll"
    private var isCut: Bool { fullHeight > cutHeight + 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if expanded {
                ScrollView {
                    Text(text).font(Self.font).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            GeometryReader { geo in
                                Color.clear.onChange(of: geo.frame(in: .named(Self.space)), initial: true) { _, frame in content = frame }
                            }
                        }
                }
                .coordinateSpace(name: Self.space)
                // Follows the text height up to the cap, so a short text leaves no blank space under it.
                .frame(height: content.height > 0 ? min(content.height, Metric.opTextMaxHeight) : Metric.opTextMaxHeight)
            } else {
                Text(text).font(Self.font).foregroundStyle(Ink.text)
                    .lineLimit(Metric.opTextLines).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(text)
                    .heightReader { cutHeight = $0 }
                    .background(alignment: .topLeading) {
                        Text(text).font(Self.font).fixedSize(horizontal: false, vertical: true).hidden()
                            .heightReader { fullHeight = $0 }
                    }
            }
            if isCut || expanded {
                Button(expanded ? "Show Less" : "Show All") { expanded.toggle() }
                    .buttonStyle(.kit)
            }
        }
        .onChange(of: expanded) { if !expanded { content = .zero } }
    }
}

extension View {
    func heightReader(_ report: @escaping (CGFloat) -> Void) -> some View {
        background { GeometryReader { geo in Color.clear.onChange(of: geo.size.height, initial: true) { _, height in report(height) } } }
    }
}
