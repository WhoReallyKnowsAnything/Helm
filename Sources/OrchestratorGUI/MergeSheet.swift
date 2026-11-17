import SwiftUI

/// Script output in a scrollable, selectable, monospaced area. Drawn as plain text: it is untrusted.
struct OutputArea: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(verbatim: text.isEmpty ? "(no output)" : text)
                .kitType(.meta).foregroundStyle(Ink.textSecondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.sm)
        }
        .frame(minHeight: Metric.outputMinHeight, maxHeight: Metric.outputMaxHeight)
        .background(Ink.terminal)
        .overlay(RoundedRectangle(cornerRadius: Metric.corner).stroke(Ink.border))
    }
}

/// Explanatory or script-derived text inside a sheet, as a footer line. Plain text: it can hold untrusted output.
struct SheetNote: View {
    let text: String

    var body: some View {
        KitFooterLine { Text(verbatim: text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }
}

/// The read-only preview, then the result of `--merge` (D-02, D-03). The sheet shows no flow logic: that lives in `MergeModel`.
struct MergeSheet: View {
    @ObservedObject var model: MergeModel
    let onClose: () -> Void

    var body: some View {
        MergeSheetContent(
            label: model.label, state: model.state, unknownPullRequestAllowed: model.unknownPullRequestAllowed,
            onConfirm: { Task { await model.confirm() } }, onClose: onClose
        )
        .task { await model.open() }
        // Closing in the middle of a run would drop the result.
        .interactiveDismissDisabled(MergeSheetContent.isBusy(model.state))
    }

    static func verdictText(_ verdict: MergeModel.Verdict) -> String {
        switch verdict {
        case .merged: return "Merged"
        case .notMerged: return "Not merged"
        case .failed: return "Failed"
        }
    }
}

/// What the Merge sheet draws, from plain data and actions, so a render test needs no model or script run.
struct MergeSheetContent: View {
    let label: String
    let state: MergeModel.State
    let unknownPullRequestAllowed: Bool
    let onConfirm: () -> Void
    let onClose: () -> Void

    static func isBusy(_ state: MergeModel.State) -> Bool {
        switch state {
        case .checking, .running: return true
        default: return false
        }
    }

    var body: some View {
        KitSheetFrame(
            title: "Merge \(label)", width: SheetWidth.large, failure: refusal, progress: progress,
            primaryTitle: isPreview ? "Merge" : nil, primaryEnabled: canConfirm,
            cancelTitle: showsClose ? "Close" : "Cancel", cancelEnabled: !Self.isBusy(state), cancel: onClose,
            primary: onConfirm
        ) { content }
    }

    private var refusal: String? {
        if case .refused(let text) = state { text } else { nil }
    }

    private var progress: String? {
        switch state {
        case .checking: "Checking the worker and reading the preview"
        case .running: "Merging. This can take a few minutes."
        default: nil
        }
    }

    private var isPreview: Bool {
        if case .preview = state { true } else { false }
    }

    private var canConfirm: Bool {
        if case .preview(_, let canConfirm) = state { canConfirm } else { false }
    }

    private var showsClose: Bool {
        switch state {
        case .refused, .result: true
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .checking, .running, .refused:
            EmptyView()
        case .preview(let output, _):
            Text("Preview (nothing is changed yet)").kitType(.meta).foregroundStyle(Ink.muted)
            OutputArea(text: output)
            if unknownPullRequestAllowed {
                note("The pull request state is unknown. Merge only if this worker has no open pull request.")
            }
        case .result(let outcome):
            Text(verbatim: "\(MergeSheet.verdictText(outcome.verdict)), exit \(outcome.status)")
                .kitType(.title).foregroundStyle(Ink.text)
            if let detail = outcome.detail { note(detail) }
            OutputArea(text: outcome.output)
            if let notice = outcome.notice { note(notice) }
        }
    }

    private func note(_ text: String) -> some View { SheetNote(text: text) }
}
