import SwiftUI

/// The fixed-height strip with a fill and a bottom hairline. Put a `Spacer()` between leading and trailing content.
/// Its content dims while the window is inactive.
struct KitHeaderBar<Content: View>: View {
    let forced: KitState?
    let content: Content
    @Environment(\.appearsActive) private var appearsActive

    init(forced: KitState? = nil, @ViewBuilder content: () -> Content) {
        self.forced = forced
        self.content = content()
    }

    var body: some View {
        let active = forced.map { $0 != .inactive } ?? appearsActive
        HStack(spacing: Space.sm) { content }
            .kitType(.body)
            .foregroundStyle(Ink.text)
            .opacity(active ? 1 : Fade.inactive)
            .padding(.horizontal, Space.md)
            .frame(maxWidth: .infinity)
            .frame(height: Metric.headerBar)
            .background(Ink.header)
            .overlay(alignment: .bottom) { Ink.border.frame(height: Metric.hairline) }
    }
}

/// The full-width bar under the tree or a terminal: the accent prompt glyph, a one-line field and the Dispatch button.
/// It only reports the action (the button, and Return in the field). The host decides what it means and clears the text.
/// It reads the disabled state from the environment, as the kit buttons do. Its content dims while the window is inactive.
struct KitPromptBar: View {
    @Binding var text: String
    var forced: KitState?
    let action: () -> Void
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.kitAccent) private var accent

    var body: some View {
        let active = forced.map { $0 != .inactive } ?? appearsActive
        HStack(spacing: Space.sm) {
            Text("❯").kitType(.body).foregroundStyle(accent.text).accessibilityHidden(true)
            TextField("", text: $text, prompt: Text("dispatch a task to a new worker").foregroundStyle(Ink.muted))
                .textFieldStyle(.plain)
                .kitType(.body)
                .foregroundStyle(Ink.text)
                .accessibilityLabel("Task to dispatch")
                .onSubmit(action)
            Button(action: action) { KitLabel("Dispatch", icon: .send) }
                .buttonStyle(.kitPrimary)
        }
        .opacity(active ? 1 : Fade.inactive)
        .padding(.horizontal, Space.md)
        .frame(maxWidth: .infinity)
        .frame(height: Metric.headerBar)
        .background(Ink.header)
        .overlay(alignment: .top) { Ink.border.frame(height: Metric.hairline) }
    }
}

/// Small monospaced text strip with a top hairline. Each child view is one line.
struct KitFooterLine<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) { content }
            .kitType(.meta)
            .foregroundStyle(Ink.textSecondary)
            .padding(Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Ink.border.frame(height: Metric.hairline) }
    }
}

/// The small bordered text box that floats over a screen.
struct KitNote: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.corner)
        Text(text)
            .kitType(.label)
            .foregroundStyle(Ink.muted)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(Ink.panel, in: shape)
            .overlay(shape.strokeBorder(Ink.border, lineWidth: Metric.hairline))
    }
}

/// The dots behind the tree: one per `Metric.dotPitch`, drawn with one `Canvas`. No timeline and no animation.
struct KitDotGrid: View {
    var body: some View {
        Canvas { context, size in
            var dots = Path()
            for x in stride(from: Space.none, to: size.width, by: Metric.dotPitch) {
                for y in stride(from: Space.none, to: size.height, by: Metric.dotPitch) {
                    dots.addRect(CGRect(x: x, y: y, width: Metric.dotSize, height: Metric.dotSize))
                }
            }
            context.fill(dots, with: .color(Ink.dotGrid))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Centred muted text that fills the space of a screen with nothing to show. An optional action sits under the text.
struct KitNotice<Action: View>: View {
    let text: String
    let action: Action

    init(text: String, @ViewBuilder action: () -> Action) {
        self.text = text
        self.action = action()
    }

    var body: some View {
        VStack(spacing: Space.sm) {
            Text(text)
                .kitType(.body)
                .foregroundStyle(Ink.muted)
                .multilineTextAlignment(.center)
            action
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension KitNotice where Action == EmptyView {
    init(text: String) { self.init(text: text) { EmptyView() } }
}
