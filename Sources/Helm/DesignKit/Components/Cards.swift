import SwiftUI

/// The look of one node in the tree. It carries no gesture: the tree puts its own tap and drag on top, and passes
/// `forced: .pressed` while that press is down. Hover and keyboard focus are real. The size comes from the caller (`TreeLayout`).
struct KitNodeCard: View {
    let title: String
    var taskTitle: String?
    var status: WorkerStatus?
    var lines: [String] = []
    var forced: KitState?
    @State private var hovering = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let hover = forced == .hover || hovering
        let pressed = forced == .pressed
        let shape = RoundedRectangle(cornerRadius: Metric.corner)
        // Only running and waiting cards take their status colour, as the fill and the border (D-13a). The others stay neutral.
        let statusColours: (fill: Color, border: Color)? = switch status {
        case .running: (Ink.runningFill, Ink.running)
        case .waiting: (Ink.waitingFill, Ink.waiting)
        default: nil
        }
        VStack(alignment: .leading) {
            Text(title).kitType(.title).foregroundStyle(Ink.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            if let taskTitle {
                Text(taskTitle).kitType(.meta).foregroundStyle(Ink.muted)
            }
            if let status { KitStatusText(status: status) }
            // Middle truncation keeps the effort at the end of `model · effort` visible when a long model name does not fit.
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).kitType(.meta).foregroundStyle(Ink.muted).truncationMode(.middle)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shape.fill(pressed ? Ink.border : statusColours?.fill ?? Ink.panel))
        .overlay(shape.strokeBorder(statusColours?.border ?? (hover || pressed ? Ink.borderStrong : Ink.border), lineWidth: Metric.hairline))
        .contentShape(shape)
        .kitFocusRing(forced == .focus || isFocused)
        .onHover { hovering = $0 }
        .kitAnimation(.hover, value: hover)
        .focusable()
        .focusEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title] + [status?.rawValue].compactMap { $0 } + lines).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

/// The bordered shell of a hold card: the command, a state line, the decision buttons and an outcome line.
/// The caller fills the command and decision slots, so the command text logic stays with the screen.
/// The border is the waiting colour, because a hold card waits on the person.
struct KitHoldCard<Command: View, Decision: View>: View {
    var stateLine: String?
    var outcome: String?
    let command: Command
    let decision: Decision

    init(stateLine: String? = nil, outcome: String? = nil, @ViewBuilder command: () -> Command, @ViewBuilder decision: () -> Decision) {
        self.stateLine = stateLine
        self.outcome = outcome
        self.command = command()
        self.decision = decision()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.corner)
        VStack(alignment: .leading, spacing: Space.xs) {
            command
            if let stateLine {
                Text(stateLine).kitType(.meta).foregroundStyle(Ink.muted)
            }
            decision
            if let outcome {
                Text(outcome).kitType(.meta).foregroundStyle(Ink.textSecondary)
                    .lineLimit(3).truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.sm)
        .background(Ink.panel, in: shape)
        .overlay(shape.strokeBorder(Ink.waiting, lineWidth: Metric.hairline))
        .accessibilityElement(children: .contain)
    }
}

/// Two buttons side by side when the width allows, stacked when not. Give the buttons `.kit` and they never wrap.
struct KitButtonPair<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.xs) { content() }
            VStack(alignment: .leading, spacing: Space.xs) { content() }
        }
    }
}
