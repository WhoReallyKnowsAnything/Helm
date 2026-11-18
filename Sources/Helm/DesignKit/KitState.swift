import SwiftUI

/// The states of design/KIT.md. Every part takes an optional one to force it: an offscreen view has no pointer,
/// no key focus and no window, so the gallery and its test cannot reach hover, pressed, focus or inactive any other way.
enum KitState: String, CaseIterable {
    case normal = "default"
    case hover, pressed, selected, inactive, disabled, focus
}

private struct KitFocusRing: ViewModifier {
    let on: Bool
    let radius: CGFloat
    @Environment(\.kitAccent) private var accent

    /// The ring sits outside the edge, so it shows on an accent fill too.
    func body(content: Content) -> some View {
        content.overlay {
            if on {
                RoundedRectangle(cornerRadius: radius + Metric.focusRing)
                    .strokeBorder(accent.text, lineWidth: Metric.focusRing)
                    .padding(-Metric.focusRing)
            }
        }
    }
}

extension View {
    /// Draws the keyboard focus ring when `on`.
    func kitFocusRing(_ on: Bool, radius: CGFloat = Metric.corner) -> some View {
        modifier(KitFocusRing(on: on, radius: radius))
    }
}
