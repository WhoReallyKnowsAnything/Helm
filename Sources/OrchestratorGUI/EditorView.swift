import SwiftUI

/// The editor screen: loads the file, then draws `EditorScreenBody`.
struct EditorView: View {
    let path: String
    let line: Int?
    let project: String?
    var rows: [WorkerRow] = []
    var workspace: WorkspaceOpening = SystemWorkspace()

    @StateObject private var store = EditorStore()

    var body: some View {
        EditorScreenBody(path: path, line: line, project: project, result: shown, workspace: workspace,
                         access: store.access, isDirty: store.isDirty, saveFailure: store.saveFailure,
                         pendingDraft: store.pendingDraft, onRestore: store.restore, onDiscard: store.discard,
                         changedOnDisk: store.changedOnDisk, onReload: store.reloadFromDisk, onKeepMine: store.keepMine,
                         workerName: EditorView.workerName(path: path, rows: rows),
                         showsDiff: store.showsDiff, diff: store.diff, onToggleDiff: store.toggleDiff,
                         onEdit: store.edit, onSave: store.save)
            .onDisappear { store.flush() }
            .task(id: path) {
                store.configure(project: project.map { URL(fileURLWithPath: $0) }, rows: rows)
                store.point(at: URL(fileURLWithPath: path))
            }
            .onChange(of: rows) { store.configure(project: project.map { URL(fileURLWithPath: $0) }, rows: $0) }
    }

    /// The loaded text is shown through the buffer, so an edit stays on screen.
    private var shown: EditorTextResult? {
        if case .text = store.result { return .text(store.buffer) }
        return store.result
    }

    /// The path under the project folder, or the full path when it is outside.
    static func relativePath(_ path: String, project: String?) -> String {
        guard let project, path.hasPrefix(project + "/") else { return path }
        return String(path.dropFirst(project.count + 1))
    }

    /// The worker whose worktree holds the file, whatever its status. Nil for a project file.
    static func workerName(path: String, rows: [WorkerRow]) -> String? {
        EditorAccess.owner(of: URL(fileURLWithPath: path), rows: rows)?.agentId
    }

    /// Save is on only for a dirty buffer of an editable file.
    static func canSave(isDirty: Bool, access: EditorAccess, changedOnDisk: Bool = false) -> Bool {
        isDirty && access.isEditable && !changedOnDisk
    }

    /// The scroll request for a typed line number, or nil when it is not a line of `text`. Nothing is shown for nil.
    static func goToLine(_ input: String, in text: String, token: Int) -> EditorScrollRequest? {
        guard let line = Int(input.trimmingCharacters(in: .whitespaces)),
              EditorText.lineRange(line, in: text) != nil else { return nil }
        return EditorScrollRequest(line: line, token: token)
    }

    /// The header button: the VS Code route of `FileOpener`, so its refusals stay in one place.
    static func openInVSCode(path: String, project: String?, workspace: WorkspaceOpening) -> FileOpenOutcome {
        guard let project else { return .refused("no project folder") }
        return FileOpener.open(path, project: URL(fileURLWithPath: project), worktree: nil, workspace: workspace)
    }
}

/// The editor screen's drawing: a header with the project-relative path, the go to line field and the VS Code button,
/// then the file text or the reason it cannot be shown.
struct EditorScreenBody: View {
    let path: String
    let line: Int?
    let project: String?
    let result: EditorTextResult?
    var workspace: WorkspaceOpening = SystemWorkspace()
    var access: EditorAccess = .editable
    var isDirty = false
    var saveFailure: String?
    var pendingDraft: String?
    var onRestore: () -> Void = {}
    var onDiscard: () -> Void = {}
    var changedOnDisk = false
    var onReload: () -> Void = {}
    var onKeepMine: () -> Void = {}
    /// The `agentId` of the worker whose worktree holds the file, whatever its status. Nil for a project file.
    var workerName: String?
    var showsDiff = false
    var diff: EditorDiff.Outcome?
    var onToggleDiff: () -> Void = {}
    var onEdit: (String) -> Void = { _ in }
    var onSave: () -> Void = {}

    @State private var typed = ""
    @State private var request: EditorScrollRequest?
    @State private var presses = 0
    @State private var refusal: String?

    var body: some View {
        VStack(spacing: Space.none) {
            KitHeaderBar {
                Text(EditorView.relativePath(path, project: project) + (isDirty ? " \u{2022}" : "")).lineLimit(1).truncationMode(.middle)
                if let workerName { Text(workerName).kitType(.meta).foregroundStyle(Ink.textSecondary).lineLimit(1) }
                if let reason = access.reason { Text("Read-only: \(reason)").kitType(.meta).foregroundStyle(Ink.muted).lineLimit(1).help(reason) }
                if let saveFailure { Text("Not saved: \(saveFailure)").kitType(.meta).foregroundStyle(Ink.muted).lineLimit(1) }
                Spacer()
                if let refusal { Text("Not opened: \(refusal)").kitType(.meta).foregroundStyle(Ink.muted) }
                if case .text(let text) = result {
                    TextField("", text: $typed, prompt: Text("go to line").foregroundStyle(Ink.muted))
                        .textFieldStyle(.plain)
                        .frame(width: Metric.goToLineWidth)
                        .onSubmit {
                            presses += 1
                            if let next = EditorView.goToLine(typed, in: text, token: presses) { request = next }
                        }
                }
                if case .text = result {
                    Button { onToggleDiff() } label: { Text(showsDiff ? "Hide diff" : "Show diff") }
                        .buttonStyle(.kit)
                }
                Button { onSave() } label: { Text("Save") }
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!EditorView.canSave(isDirty: isDirty, access: access, changedOnDisk: changedOnDisk))
                Button { open() } label: { Text("Open in VS Code") }
                    .buttonStyle(.kit)
            }
            if changedOnDisk {
                EditorDiskBanner(onReload: onReload, onKeepMine: onKeepMine)
            }
            if pendingDraft != nil {
                EditorDraftBanner(onRestore: onRestore, onDiscard: onDiscard)
            }
            switch result {
            case .text where showsDiff:
                switch diff {
                case .blocks(let blocks): EditorDiffView(blocks: blocks)
                case .failed(let reason): KitNotice(text: "Cannot read the diff: \(reason)")
                case nil: Spacer()
                }
            case .text(let text):
                EditorTextView(text: text, language: SyntaxTokenizer.language(forExtension: (path as NSString).pathExtension),
                               request: request ?? line.map { EditorScrollRequest(line: $0, token: 0) },
                               isEditable: access.isEditable, onEdit: onEdit)
                    .id(path)
                    .background(Ink.background)
            case .unsupported(let reason):
                KitNotice(text: "Cannot show this file: \(reason)")
            case nil:
                Spacer()
            }
        }
    }

    private func open() {
        if case .refused(let reason) = EditorView.openInVSCode(path: path, project: project, workspace: workspace) {
            refusal = reason
        } else {
            refusal = nil
        }
    }
}

/// The strip shown when the file changed on disk while the buffer has unsaved edits. Save is off until the user picks.
struct EditorDiskBanner: View {
    let onReload: () -> Void
    let onKeepMine: () -> Void

    var body: some View {
        KitHeaderBar {
            Text("This file changed on disk.").kitType(.meta).foregroundStyle(Ink.muted).lineLimit(1)
            Spacer()
            Button { onReload() } label: { Text("Reload") }
                .buttonStyle(.kitPrimary)
            Button { onKeepMine() } label: { Text("Keep Mine") }
                .buttonStyle(.kit)
        }
    }
}

/// The strip shown when an unsaved draft was kept. The text below it stays the disk text until the user picks.
struct EditorDraftBanner: View {
    let onRestore: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        KitHeaderBar {
            Text("An unsaved draft of this file was kept.").kitType(.meta).foregroundStyle(Ink.muted).lineLimit(1)
            Spacer()
            Button { onRestore() } label: { Text("Restore") }
                .buttonStyle(.kitPrimary)
            Button { onDiscard() } label: { Text("Discard") }
                .buttonStyle(.kit)
        }
    }
}
