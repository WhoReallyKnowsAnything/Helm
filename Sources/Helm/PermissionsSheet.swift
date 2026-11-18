import SwiftUI

/// The `/permissions` sheet (D-07): the allow, ask and deny rules of the Local, Project and User settings files.
struct PermissionScope: Equatable, Hashable {
    let name: String
    let note: String
    let path: String

    /// Local (the default selection), Project, User. A root session (cwd is home) or no init yet gives only User.
    static func scopes(cwd: String, home: String) -> [PermissionScope] {
        let user = PermissionScope(name: "User", note: "all your sessions", path: home + "/.claude/settings.json")
        guard !cwd.isEmpty, FolderCheck.realPath(cwd) != FolderCheck.realPath(home) else { return [user] }
        return [
            PermissionScope(name: "Local", note: "this project, not committed", path: cwd + "/.claude/settings.local.json"),
            PermissionScope(name: "Project", note: "shared, committed", path: cwd + "/.claude/settings.json"),
            user,
        ]
    }
}

/// A settings file read for display only (`JSONSerialization`, never written back). A missing file reads as empty.
struct SettingsRead {
    var json: [String: Any] = [:]
    var reason: String?

    init(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else {
            if FileManager.default.fileExists(atPath: path) { reason = "Cannot read \(path)." }
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            reason = "\(path) is not a JSON object, so it cannot be edited here."
            return
        }
        json = object
    }

    func rules(_ list: String) -> [String] { (json["permissions"] as? [String: Any])?[list] as? [String] ?? [] }
}

struct PermissionsSheet: View {
    static let lists = ["allow", "ask", "deny"]
    let scopes: [PermissionScope]
    @Binding var failure: String?
    @State private var scope: PermissionScope
    @State private var file: SettingsRead
    @State private var newRule = ""
    @State private var newList = "allow"

    init(cwd: String, home: String = NSHomeDirectory(), failure: Binding<String?>) {
        let scopes = PermissionScope.scopes(cwd: cwd, home: home)
        self.scopes = scopes
        _failure = failure
        _scope = State(initialValue: scopes[0])
        _file = State(initialValue: SettingsRead(path: scopes[0].path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Picker("Scope", selection: $scope) {
                ForEach(scopes, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: scope) { failure = nil; reload() }
            Text(verbatim: scope.note + ": " + scope.path).kitType(.meta).foregroundStyle(Ink.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let reason = file.reason {
                Text(verbatim: reason).kitType(.body).foregroundStyle(Ink.textSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(Self.lists, id: \.self) { list in
                            Text(list).kitType(.meta).foregroundStyle(Ink.muted)
                            if file.rules(list).isEmpty { Text("none").kitType(.meta).foregroundStyle(Ink.muted) }
                            ForEach(file.rules(list), id: \.self) { rule in row(rule, list) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Metric.ruleListMaxHeight)
                HStack(spacing: Space.sm) {
                    TextField("Rule, for example Bash(npm test:*)", text: $newRule).textFieldStyle(.roundedBorder)
                    Picker("List", selection: $newList) {
                        ForEach(Self.lists, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button {
                        let rule = newRule, list = newList
                        run({ SettingsFileWriter.addRule(rule, to: list, in: $0) }) { newRule = "" }
                    } label: { KitLabel("Add", icon: .add) }
                    .buttonStyle(.kit)
                }
            }
            Text("A change applies to sessions started after it.").kitType(.meta).foregroundStyle(Ink.muted)
        }
    }

    private func row(_ rule: String, _ list: String) -> some View {
        HStack(spacing: Space.sm) {
            Text(verbatim: rule).kitType(.body).foregroundStyle(Ink.text)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { run { SettingsFileWriter.removeRule(rule, from: list, in: $0) } } label: { KitImage(.delete) }
                .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove \(rule)")
        }
    }

    /// Writes off the main actor, then reads the file again. A refusal shows in the sheet's failure line.
    private func run(_ write: @escaping (String) -> String?, onSuccess: @escaping () -> Void = {}) {
        let path = scope.path
        Task {
            failure = await Task.detached { write(path) }.value
            if failure == nil { onSuccess() }
            reload()
        }
    }

    private func reload() { file = SettingsRead(path: scope.path) }
}
