import SwiftUI

/// The standard and the primary button of design/KIT.md. `forced` pins a state for the gallery, else the state is real.
/// A disabled button carries its own dimming, so call sites need no `.opacity`.
struct KitButtonStyle: ButtonStyle {
    enum Kind { case standard, primary }

    var kind = Kind.standard
    var forced: KitState?

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, kind: kind, forced: forced)
    }

    private struct ButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let forced: KitState?
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.kitAccent) private var accent

        var body: some View {
            let off = forced == .disabled || !isEnabled
            let pressed = !off && (forced == .pressed || configuration.isPressed)
            let hover = !off && (forced == .hover || hovering)
            let shape = RoundedRectangle(cornerRadius: Metric.corner)
            configuration.label
                .kitType(.label)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(kind == .primary ? accent.onAccent : Ink.textSecondary)
                .padding(.horizontal, Space.sm)
                .frame(height: Metric.control)
                .background(fill(pressed: pressed, hover: hover), in: shape)
                .overlay { if kind == .standard { shape.strokeBorder(Ink.border, lineWidth: Metric.hairline) } }
                .contentShape(shape)
                .kitFocusRing(!off && (forced == .focus || isFocused))
                .opacity(off ? Fade.disabled : 1)
                .onHover { hovering = $0 }
                .kitAnimation(.hover, value: hover)
                .kitAnimation(.press, value: pressed)
                .focusEffectDisabled()
        }

        private func fill(pressed: Bool, hover: Bool) -> Color {
            switch kind {
            case .primary: accent.fill.opacity(pressed ? Fade.pressed : hover ? Fade.hover : 1)
            case .standard: pressed ? Ink.borderStrong : hover ? Ink.border : Ink.panel
            }
        }
    }
}

/// The standard button for a prompt option under a tree node: the look of `.kit`, but a label wider than the room wraps onto
/// more lines, whole, and the button grows in height (a minimum height instead of a fixed one). Tree prompt buttons only.
struct KitPromptButtonStyle: ButtonStyle {
    var forced: KitState?

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, forced: forced)
    }

    private struct ButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let forced: KitState?
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let off = forced == .disabled || !isEnabled
            let pressed = !off && (forced == .pressed || configuration.isPressed)
            let hover = !off && (forced == .hover || hovering)
            let shape = RoundedRectangle(cornerRadius: Metric.corner)
            configuration.label
                .kitType(.label)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Ink.textSecondary)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .frame(minHeight: Metric.control)
                .background(pressed ? Ink.borderStrong : hover ? Ink.border : Ink.panel, in: shape)
                .overlay { shape.strokeBorder(Ink.border, lineWidth: Metric.hairline) }
                .contentShape(shape)
                .kitFocusRing(!off && (forced == .focus || isFocused))
                .opacity(off ? Fade.disabled : 1)
                .onHover { hovering = $0 }
                .kitAnimation(.hover, value: hover)
                .kitAnimation(.press, value: pressed)
                .focusEffectDisabled()
        }
    }
}

extension ButtonStyle where Self == KitButtonStyle {
    static var kit: KitButtonStyle { KitButtonStyle() }
    static var kitPrimary: KitButtonStyle { KitButtonStyle(kind: .primary) }
}

extension ButtonStyle where Self == KitPromptButtonStyle {
    static var kitPrompt: KitPromptButtonStyle { KitPromptButtonStyle() }
}
