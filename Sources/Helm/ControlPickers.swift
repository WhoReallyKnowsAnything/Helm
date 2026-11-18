import SwiftUI

/// What the two pickers list and do, apart from the drawing, so tests need no click (D-10).
struct ControlPickerModel {
    /// The current model as the log writes it, such as `claude-haiku-5-5`. Nil when unknown.
    var currentModel: String?
    /// Nil until the user picks one: the log has no effort field (MODELS.md).
    var currentEffort: String?
    var disabled = false
    var onModel: (String) -> Void
    var onEffort: (String) -> Void
    var subagentCount = 0
    var onSubagents: () -> Void = {}

    /// `subagentCount` counts running subagents only, so the button shows only while one runs.
    var showsSubagents: Bool { subagentCount > 0 }

    var subagentsTitle: String { subagentCount > 0 ? "Subagents (\(subagentCount))" : "Subagents" }

    var models: [String] { ["opus", "sonnet", "haiku"] }
    var efforts: [String] { ControlLineWriter.efforts }

    /// What a choice sends: Opus and Sonnet take the 1M context, Haiku its default.
    static func sentModel(_ name: String) -> String { name == "haiku" ? name : name + "[1m]" }

    /// `opus[1m]` and `opus` both report `claude-opus-…` (MODELS.md notes), so the choice matches the base name.
    func isCurrent(model name: String) -> Bool { currentModel?.contains(name) ?? false }

    func isCurrent(effort level: String) -> Bool { currentEffort == level }

    /// Display only: the value sent to Claude stays lowercase.
    static func label(_ value: String) -> String { value.prefix(1).uppercased() + value.dropFirst() }

    /// The seam for the click: a disabled picker calls nothing.
    func pick(model name: String) { if !disabled { onModel(Self.sentModel(name)) } }
    func pick(effort level: String) { if !disabled { onEffort(level) } }
}

/// The model and effort pickers next to the prompt box. Choosing an item calls a closure and changes nothing else.
struct ControlPickers: View {
    let model: ControlPickerModel

    var body: some View {
        HStack(spacing: Space.sm) {
            if model.showsSubagents {
                Button(model.subagentsTitle, action: model.onSubagents).buttonStyle(.kit).fixedSize()
            }
            Spacer(minLength: Space.none)
            Group {
                menu("Model", items: model.models, current: model.isCurrent(model:), choose: model.pick(model:))
                menu("Effort", items: model.efforts, current: model.isCurrent(effort:), choose: model.pick(effort:))
            }
            .disabled(model.disabled)
        }
        .padding(.horizontal, Space.lg + Space.md)
    }

    private func menu(
        _ title: String, items: [String], current: @escaping (String) -> Bool, choose: @escaping (String) -> Void
    ) -> some View {
        Menu(title) {
            ForEach(items, id: \.self) { item in
                Button((current(item) ? "• " : "") + ControlPickerModel.label(item)) { choose(item) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.kit)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
