import SwiftUI

/// The Cmd-, window: the accent colour (D-10), the conversation text font and the stage sessions.
struct AppSettingsView: View {
    @Environment(\.kitAccent) private var accent
    @AppStorage(ConversationFont.familyKey) private var family = ConversationFont.defaultFamily
    @AppStorage(ConversationFont.sizeKey) private var size = ConversationFont.defaultSize
    @State private var families = [ConversationFont.defaultFamily]

    private var shownSize: Binding<Double> {
        Binding(get: { ConversationFont(family: family, size: size).size }, set: { size = $0 })
    }

    var body: some View {
        Form {
            Section("Accent") {
                AccentPicker()
            }
            Section("Conversation text") {
                Picker("Font", selection: $family) {
                    if !families.contains(family) { Text("\(family) (missing)").tag(family) }
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: shownSize, in: ConversationFont.sizes, step: 1) { Text("Size \(Int(shownSize.wrappedValue)) pt") }
            }
            Section("Stage sessions") {
                ForEach(StageRouting.stages, id: \.rawValue) {
                    StageRow(name: $0.rawValue, fallback: StageRouting.fallback($0))
                }
                StageRow(name: StageRouting.utility, fallback: StageRouting.utilityFallback)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(accent.fill)
        .background(Ink.background)
        .frame(width: Metric.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .task { families = await Task.detached { ConversationFont.loadFamilies() }.value }
    }
}

/// One stage: a model picker and an effort picker. Each stores its own key, so the board reads the choice back.
private struct StageRow: View {
    let name: String
    @AppStorage private var model: String
    @AppStorage private var effort: String

    init(name: String, fallback base: StageRouting.Entry) {
        self.name = name
        _model = AppStorage(wrappedValue: base.model ?? StageRouting.none, StageRouting.modelKey(name))
        _effort = AppStorage(wrappedValue: base.effort ?? StageRouting.none, StageRouting.effortKey(name))
    }

    var body: some View {
        LabeledContent(name.capitalized) {
            HStack {
                Picker("Model", selection: $model) {
                    ForEach([StageRouting.none] + StageRouting.models, id: \.self) { Text($0).tag($0) }
                }
                Picker("Effort", selection: $effort) {
                    ForEach([StageRouting.none] + StageRouting.efforts, id: \.self) { Text($0).tag($0) }
                }
            }
            .labelsHidden()
        }
    }
}

/// One swatch per accent. The choice goes through `AccentStore` and `@AppStorage` redraws every open window at once.
private struct AccentPicker: View {
    @AppStorage(AccentStore.key) private var stored = AccentChoice.default.rawValue

    var body: some View {
        LabeledContent("Accent") {
            HStack(spacing: Space.sm) {
                ForEach(AccentChoice.allCases) { choice in
                    let selected = choice.rawValue == stored
                    Button { AccentStore(defaults: .standard).choice = choice } label: {
                        Circle()
                            .fill(Ink.swatch(for: choice).fill)
                            .overlay { Circle().strokeBorder(selected ? Ink.text : Ink.border, lineWidth: selected ? Metric.focusRing : Metric.hairline) }
                            .frame(width: Metric.accentSwatch, height: Metric.accentSwatch)
                    }
                    .buttonStyle(.plain)
                    .help(choice.name)
                    .accessibilityLabel(choice.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}
