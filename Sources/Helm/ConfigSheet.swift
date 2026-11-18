import SwiftUI

/// The `/config` sheet (D-08): 4 user-scope keys of `~/.claude/settings.json` that change a headless session.
enum ConfigKeys {
    static let models = ["opus", "sonnet", "haiku"]
    static let modes = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]

    static let autoCompact = ["autoCompactEnabled"]
    static let model = ["model"]
    static let defaultMode = ["permissions", "defaultMode"]
    static let coAuthoredBy = ["includeCoAuthoredBy"]

    static func autoCompact(_ json: [String: Any]) -> Bool? { json["autoCompactEnabled"] as? Bool }
    static func coAuthoredBy(_ json: [String: Any]) -> Bool? { json["includeCoAuthoredBy"] as? Bool }
    static func rawModel(_ json: [String: Any]) -> String? { json["model"] as? String }
    static func defaultMode(_ json: [String: Any]) -> String? { (json["permissions"] as? [String: Any])?["defaultMode"] as? String }

    /// `sonnet` or `sonnet[1m]` selects Sonnet (same for Opus and Haiku). Any other value selects nothing.
    static func model(_ json: [String: Any]) -> String? {
        guard let raw = rawModel(json) else { return nil }
        let base = raw.hasSuffix("[1m]") ? String(raw.dropLast(4)) : raw
        return models.contains(base) ? base : nil
    }

    /// The JSON text Task 1's writer puts in place of the old value.
    static func text(_ flag: Bool) -> String { flag ? "true" : "false" }
    static func text(model: String) -> String { SettingsFileWriter.jsonString(ControlPickerModel.sentModel(model)) }
    static func text(mode: String) -> String { SettingsFileWriter.jsonString(mode) }
}

struct ConfigSheet: View {
    let path: String
    @Binding var failure: String?
    @Environment(\.kitAccent) private var accent
    @State private var file: SettingsRead

    init(home: String = NSHomeDirectory(), failure: Binding<String?>) {
        path = home + "/.claude/settings.json"
        _failure = failure
        _file = State(initialValue: SettingsRead(path: home + "/.claude/settings.json"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(verbatim: "User settings: " + path).kitType(.meta).foregroundStyle(Ink.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let reason = file.reason {
                Text(verbatim: reason).kitType(.body).foregroundStyle(Ink.textSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("Auto-compact", isOn: Binding(get: { ConfigKeys.autoCompact(file.json) ?? false },
                                                     set: { run(ConfigKeys.autoCompact, ConfigKeys.text($0)) }))
                Picker("Model", selection: Binding(get: { ConfigKeys.model(file.json) ?? "" },
                                                   set: { run(ConfigKeys.model, ConfigKeys.text(model: $0)) })) {
                    if ConfigKeys.model(file.json) == nil { Text(verbatim: ConfigKeys.rawModel(file.json) ?? "not set").tag("") }
                    ForEach(ConfigKeys.models, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Permission mode", selection: Binding(get: { ConfigKeys.defaultMode(file.json) ?? "" },
                                                             set: { run(ConfigKeys.defaultMode, ConfigKeys.text(mode: $0)) })) {
                    if !ConfigKeys.modes.contains(ConfigKeys.defaultMode(file.json) ?? "") {
                        Text(verbatim: ConfigKeys.defaultMode(file.json) ?? "not set").tag("")
                    }
                    ForEach(ConfigKeys.modes, id: \.self) { Text($0).tag($0) }
                }
                if ConfigKeys.defaultMode(file.json) == "bypassPermissions" {
                    HStack(spacing: Space.sm) {
                        KitImage(.warning)
                        Text("Every tool then runs without asking.")
                    }
                    .kitType(.meta).foregroundStyle(Ink.waiting)
                }
                Toggle("Co-authored-by trailer on commits", isOn: Binding(get: { ConfigKeys.coAuthoredBy(file.json) ?? false },
                                                                          set: { run(ConfigKeys.coAuthoredBy, ConfigKeys.text($0)) }))
            }
            Text("A change applies to sessions started after it.").kitType(.meta).foregroundStyle(Ink.muted)
        }
        .kitType(.body)
        .tint(accent.fill)
    }

    /// Writes off the main actor, then reads the file again. A refusal shows in the sheet's failure line.
    private func run(_ key: [String], _ value: String) {
        let path = path
        Task {
            failure = await Task.detached { SettingsFileWriter.set(key, to: value, in: path) }.value
            file = SettingsRead(path: path)
        }
    }
}
