import SwiftUI

/// One tab of the stage tab bar.
struct KitStageTab: Identifiable, Equatable {
    let id: String
    let title: String
    var enabled = true
}

/// The look of one stage tab: no fill at default, border colour on hover, borderStrong when pressed, selectedRow with an
/// accent underline when selected. `forced` pins a state for the gallery, else the state is real.
struct KitStageTabStyle: ButtonStyle {
    var selected = false
    var forced: KitState?

    func makeBody(configuration: Configuration) -> some View {
        TabBody(configuration: configuration, selected: selected, forced: forced)
    }

    private struct TabBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let forced: KitState?
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.kitAccent) private var accent

        var body: some View {
            let off = forced == .disabled || !isEnabled
            let isSelected = selected || forced == .selected
            let pressed = !off && (forced == .pressed || configuration.isPressed)
            let hover = !off && (forced == .hover || hovering)
            let shape = RoundedRectangle(cornerRadius: Metric.corner)
            configuration.label
                .kitType(.label)
                .fontWeight(isSelected ? .semibold : nil)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isSelected ? Ink.text : Ink.textSecondary)
                .padding(.horizontal, Space.sm)
                .frame(height: Metric.control)
                .background(pressed ? Ink.borderStrong : hover ? Ink.border : isSelected ? Ink.selectedRow : Color.clear, in: shape)
                .overlay(alignment: .bottom) { if isSelected { accent.fill.frame(height: Metric.selectedEdge) } }
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

/// The stage tab bar: `tabs` at the left, a gap, then `trailing` set apart at the right end. One tab is selected.
/// `forcedTab` and `forced` pin one tab into one state for the gallery.
struct KitStageTabBar: View {
    let tabs: [KitStageTab]
    var trailing: [KitStageTab] = []
    let selection: String
    var forcedTab: String?
    var forced: KitState?
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(tabs) { tab($0) }
            Spacer(minLength: Space.lg)
            ForEach(trailing) { tab($0) }
        }
        .padding(.horizontal, Space.md)
        .frame(maxWidth: .infinity)
        .frame(height: Metric.headerBar)
        .background(Ink.header)
        .overlay(alignment: .bottom) { Ink.border.frame(height: Metric.hairline) }
    }

    private func tab(_ tab: KitStageTab) -> some View {
        let isSelected = tab.id == selection
        return Button { onSelect(tab.id) } label: { Text(tab.title) }
            .buttonStyle(KitStageTabStyle(selected: isSelected, forced: tab.id == forcedTab ? forced : nil))
            .disabled(!tab.enabled)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One phase in the picker.
struct KitPhaseOption: Identifiable, Equatable {
    let id: String
    let name: String
}

/// The phase picker: a standard button that opens a menu of the phases. It shows the picked phase number and name.
struct KitPhasePicker: View {
    let phases: [KitPhaseOption]
    let picked: String
    var forced: KitState?
    let onPick: (String) -> Void

    var body: some View {
        let name = phases.first { $0.id == picked }?.name ?? ""
        Menu {
            ForEach(phases) { phase in
                Button("\(phase.id)  \(phase.name)") { onPick(phase.id) }
            }
        } label: { Text("Phase \(picked)  \(name)  ▾") }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(KitButtonStyle(forced: forced))
            .fixedSize()
            .accessibilityLabel("Phase \(picked) \(name)")
    }
}

/// The stage action row: one primary button (off with a reason line when `primaryReason` is set), the secondary standard
/// buttons, and at the right end one menu whose title the caller sets ("Suggested", or an overflow title). No menu when `menuTitle` is nil.
struct KitStageActionRow<Secondary: View, MenuItems: View>: View {
    let primaryTitle: String
    var primaryReason: String?
    var menuTitle: String?
    var forced: KitState?
    let onPrimary: () -> Void
    let secondary: Secondary
    let menuItems: MenuItems

    init(primaryTitle: String, primaryReason: String? = nil, menuTitle: String? = nil, forced: KitState? = nil,
         onPrimary: @escaping () -> Void, @ViewBuilder secondary: () -> Secondary, @ViewBuilder menu: () -> MenuItems) {
        self.primaryTitle = primaryTitle
        self.primaryReason = primaryReason
        self.menuTitle = menuTitle
        self.forced = forced
        self.onPrimary = onPrimary
        self.secondary = secondary()
        self.menuItems = menu()
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            Button(action: onPrimary) { Text(primaryTitle) }
                .buttonStyle(KitButtonStyle(kind: .primary, forced: forced))
                .disabled(primaryReason != nil)
            if let primaryReason { Text(primaryReason).kitType(.meta).foregroundStyle(Ink.textSecondary) }
            secondary
            Spacer(minLength: Space.sm)
            if let menuTitle {
                Menu { menuItems } label: { Text("\(menuTitle)  ▾") }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.kit)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
