import SwiftUI

/// The run-record screen: scope picker, role rows, tweaks and receipts from `trace render` and `trace suggest`.
/// Loads on appear, on a project change, on a picker change and on Refresh, and at no other time (D-07).
struct RunRecordView: View {
    let project: String?
    var rows: [WorkflowBoard.Row] = []
    var message: String?
    /// Why the tweak buttons are off, nil when they work.
    var chipsOff: String?
    var onTweak: (_ action: String, _ proposed: String) -> Void = { _, _ in }

    @StateObject private var store = RunRecordStore()
    @State private var expanded: Set<String> = []

    /// A line that can hold a file path: a link when a project is open (D-06), else plain text.
    @ViewBuilder private func linked(_ line: String) -> some View {
        if let project {
            FileLinkView(text: line, project: URL(fileURLWithPath: project), worktree: nil)
        } else {
            Text(line)
        }
    }

    var body: some View {
        let text = RunRecordText.make(phase: store.phase, result: store.result)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Run record").kitType(.section).foregroundStyle(Ink.text)
                KitStageActionRow(primaryTitle: "Refresh", onPrimary: { store.refresh() }, secondary: {
                    Picker("Scope", selection: Binding(get: { store.phase }, set: { store.select(phase: $0) })) {
                        ForEach(RunRecordText.options(rows: rows), id: \.phase) { Text($0.label).tag($0.phase) }
                    }
                    .labelsHidden()
                }, menu: { EmptyView() })
                if store.result == nil { Text("Loading").kitType(.meta).foregroundStyle(Ink.textSecondary) }
                ForEach(text.reasons, id: \.self) { linked($0).kitType(.meta).foregroundStyle(Ink.waiting) }
                if let scope = text.scopeLine { linked(scope).kitType(.meta).foregroundStyle(Ink.textSecondary) }
                ForEach(text.roles, id: \.name) { role in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.sm) {
                            Text(role.name).kitType(.section).foregroundStyle(Ink.text)
                            Button { toggle(role.name) } label: { Text(expanded.contains(role.name) ? "Hide" : "Show") }
                                .buttonStyle(.kit)
                        }
                        Text(role.figures).kitType(.meta).foregroundStyle(Ink.text)
                        Text(role.wallClock).kitType(.meta).foregroundStyle(Ink.textSecondary)
                        if expanded.contains(role.name) {
                            ForEach(Array(role.dispatchRows.enumerated()), id: \.offset) { _, row in
                                Text(row).kitType(.meta).foregroundStyle(Ink.textSecondary)
                            }
                        }
                    }
                }
                if store.result?.suggest != nil { tweaks(text) }
                if !text.receipts.isEmpty {
                    Text("Receipts").kitType(.section).foregroundStyle(Ink.text)
                    ForEach(Array(text.receipts.enumerated()), id: \.offset) { _, line in
                        linked(line).kitType(.meta).foregroundStyle(Ink.textSecondary)
                    }
                }
                if let message { Text(message).kitType(.meta).foregroundStyle(Ink.textSecondary) }
            }
            .padding(Space.sm)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.open(project: project) }
        .onChange(of: project) { store.open(project: project) }
    }

    @ViewBuilder private func tweaks(_ text: RunRecordText) -> some View {
        Text("Tweaks").kitType(.section).foregroundStyle(Ink.text)
        if let empty = text.emptyLine { Text(empty).kitType(.meta).foregroundStyle(Ink.textSecondary) }
        ForEach(text.tweaks, id: \.number) { tweak in
            VStack(alignment: .leading, spacing: Space.xs) {
                linked("\(tweak.number). \(tweak.subject)  \(tweak.action)  current \(tweak.current)  \(tweak.direction)  proposed \(tweak.proposed)")
                    .kitType(.meta).foregroundStyle(Ink.text)
                linked(tweak.evidence).kitType(.meta).foregroundStyle(Ink.textSecondary)
                if let pair = tweak.pair {
                    HStack(spacing: Space.sm) {
                        Button { onTweak(pair.action, pair.proposed) } label: { Text("Send to /cad-config") }
                            .buttonStyle(.kit)
                            .disabled(chipsOff != nil)
                        if let chipsOff { Text(chipsOff).kitType(.meta).foregroundStyle(Ink.textSecondary) }
                    }
                }
            }
        }
    }

    private func toggle(_ name: String) {
        if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
    }
}
