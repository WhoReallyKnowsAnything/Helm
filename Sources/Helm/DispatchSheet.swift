import SwiftUI

/// The open Notion tasks of the selected project, from the orchestrator's task-list file (D-14). A pick types one
/// line into the orchestrator pane and closes the sheet. Titles are untrusted, so they are drawn as plain text.
struct DispatchSheet: View {
    @ObservedObject var store: TaskListStore
    @StateObject private var model: DispatchModel
    let now: Date
    let onSent: () -> Void
    let onClose: () -> Void

    static let duplicateReason = "same title as another task, the orchestrator cannot tell them apart"

    init(store: TaskListStore, base: String, now: Date, onSent: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.store = store
        self.now = now
        self.onSent = onSent
        self.onClose = onClose
        _model = StateObject(wrappedValue: DispatchModel(deliver: { InboxDelivery.deliver($0, base: base) }))
    }

    var body: some View {
        DispatchSheetContent(
            list: store.list, failure: store.failure, message: model.message, isSending: model.isSending, now: now,
            onPick: { title in Task { await model.pick(title: title) } }, onClose: onClose
        )
        .onChange(of: model.sent) { if model.sent { onSent() } }
    }
}

/// What the Dispatch sheet draws, from plain data and actions, so a render test needs no store or pane.
struct DispatchSheetContent: View {
    let list: TaskList?
    let failure: String?
    let message: String?
    let isSending: Bool
    let now: Date
    let onPick: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        KitSheetFrame(title: "Dispatch", width: SheetWidth.large, cancelTitle: "Close", cancel: onClose) {
            if let failure { line(failure) }
            if let message { line(message) }
            if let list, !list.tasks.isEmpty {
                Text(verbatim: "Updated \(list.ageText(now: now)) ago")
                    .kitType(.meta).foregroundStyle(Ink.muted)
                let duplicates = list.duplicateTitles
                ScrollView {
                    VStack(spacing: Space.none) {
                        ForEach(list.groups, id: \.root) { group in
                            row(list.tasks[group.root], duplicates: duplicates)
                            if !group.children.isEmpty {
                                DisclosureGroup("\(group.children.count) subtask\(group.children.count == 1 ? "" : "s")") {
                                    VStack(spacing: Space.none) {
                                        ForEach(group.children, id: \.self) { row(list.tasks[$0], duplicates: duplicates) }
                                    }
                                }
                                .kitType(.meta).foregroundStyle(Ink.muted)
                                .padding(.leading, Space.lg).padding(.vertical, Space.xs)
                            }
                        }
                    }
                }
                .frame(maxHeight: Metric.taskListMaxHeight)
            } else {
                Text("No open tasks in the task-list file.")
                    .kitType(.meta).foregroundStyle(Ink.muted)
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(verbatim: text)
            .kitType(.meta).foregroundStyle(Ink.textSecondary)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ task: NotionTask, duplicates: Set<String>) -> some View {
        HStack(spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: task.title)
                    .kitType(.label).foregroundStyle(Ink.text)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if duplicates.contains(task.title) {
                    KitLabel(DispatchSheet.duplicateReason, icon: .warning)
                        .kitType(.meta).foregroundStyle(Ink.muted)
                }
            }
            Text(verbatim: task.status).kitType(.meta).foregroundStyle(Ink.muted)
            if let priority = task.priority {
                Text(verbatim: priority).kitType(.meta).foregroundStyle(Ink.muted)
            }
            Button { onPick(task.title) } label: { Text("Pick") }
                .buttonStyle(.kitPrimary)
                .disabled(isSending)
                .accessibilityLabel(Text(verbatim: "Pick " + task.title))
        }
        .padding(.vertical, Space.sm)
        .overlay(alignment: .bottom) { Ink.border.frame(height: Metric.hairline) }
    }
}
