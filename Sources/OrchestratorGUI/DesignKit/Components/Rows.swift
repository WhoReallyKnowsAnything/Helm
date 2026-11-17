import SwiftUI

extension WorkerStatus {
    /// The fixed status colour (D-07). The accent choice never changes it, and a person always sees the word next to it.
    var ink: Color {
        switch self {
        case .waiting: Ink.waiting
        case .running: Ink.running
        case .stalled: Ink.stalled
        case .finished: Ink.merged
        case .dead: Ink.stalled
        }
    }
}

/// A filled circle in the status colour. It carries no meaning alone, so VoiceOver skips it and reads `KitStatusText`.
struct KitStatusDot: View {
    let status: WorkerStatus

    var body: some View {
        Circle().fill(status.ink)
            .frame(width: Metric.statusDot, height: Metric.statusDot)
            .accessibilityHidden(true)
    }
}

/// The status word in the status colour.
struct KitStatusText: View {
    let status: WorkerStatus

    var body: some View {
        Text(status.rawValue).kitType(.meta).foregroundStyle(status.ink)
    }
}

/// The dot that says a project needs the person.
struct KitAlertDot: View {
    var body: some View {
        Circle().fill(Ink.waiting)
            .frame(width: Metric.statusDot, height: Metric.statusDot)
            .accessibilityLabel("Needs attention")
    }
}

/// One project in the sidebar: a real `Button`, so keyboard focus and VoiceOver work.
struct KitSidebarRow: View {
    let title: String
    let id: String
    var needsAttention = false
    var selected = false
    var forced: KitState?
    let action: () -> Void

    var body: some View {
        let isSelected = selected || forced == .selected || forced == .inactive
        Button(action: action) {
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading) {
                    Text(title).kitType(.body).fontWeight(isSelected ? .semibold : nil).foregroundStyle(Ink.text)
                    Text(id).kitType(.meta).foregroundStyle(Ink.muted)
                }
                Spacer(minLength: 0)
                if needsAttention { KitAlertDot() }
            }
            .lineLimit(1)
        }
        .buttonStyle(KitSidebarRowStyle(selected: isSelected, forced: forced))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A project with no live session: not a `Button`, so it cannot be selected. The caller attaches the
/// `.contextMenu` ("Remove from list"), so the row stays a plain view.
struct KitDormantRow: View {
    let title: String
    let id: String
    /// Runs the one Restore press. The default does nothing, so a caller with no restore flow still compiles.
    var restore: () -> Void = {}
    /// While true the button is disabled and shows "Restoring".
    var running = false

    var body: some View {
        HStack(spacing: Space.sm) {
            VStack(alignment: .leading) {
                Text(title).kitType(.body).foregroundStyle(Ink.text)
                Text(id).kitType(.meta).foregroundStyle(Ink.muted)
            }
            // Only the text dims; the button keeps its full look.
            .opacity(Fade.disabled)
            Spacer(minLength: 0)
            Button(running ? "Restoring" : "Restore", action: restore)
                .buttonStyle(.kit)
                .disabled(running)
        }
        .lineLimit(1)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Metric.corner))
        .contentShape(RoundedRectangle(cornerRadius: Metric.corner))
    }
}

/// The look of `KitSidebarRow`. A selected row has a filled body and an accent edge on the left, and both dim while the window is inactive.
struct KitSidebarRowStyle: ButtonStyle {
    let selected: Bool
    var forced: KitState?

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected, forced: forced)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let forced: KitState?
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.appearsActive) private var appearsActive
        @Environment(\.kitAccent) private var accent

        var body: some View {
            let off = forced == .disabled || !isEnabled
            let active = forced.map { $0 != .inactive } ?? appearsActive
            let pressed = !off && (forced == .pressed || configuration.isPressed)
            let hover = !off && (forced == .hover || hovering)
            let shape = RoundedRectangle(cornerRadius: Metric.corner)
            let weight = active ? 1 : Fade.inactive
            configuration.label
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill(selected: selected, pressed: pressed, hover: hover, weight: weight), in: shape)
                .overlay(alignment: .leading) {
                    if selected { Rectangle().fill(accent.fill.opacity(weight)).frame(width: Metric.selectedEdge) }
                }
                .clipShape(shape)
                .contentShape(shape)
                .kitFocusRing(!off && (forced == .focus || isFocused))
                .opacity(off ? Fade.disabled : 1)
                .onHover { hovering = $0 }
                .kitAnimation(.hover, value: hover)
                .kitAnimation(.press, value: pressed)
                .focusEffectDisabled()
        }

        private func fill(selected: Bool, pressed: Bool, hover: Bool, weight: Double) -> Color {
            if pressed { return Ink.borderStrong }
            if selected { return Ink.selectedRow.opacity(weight) }
            return hover ? Ink.border : .clear
        }
    }
}
