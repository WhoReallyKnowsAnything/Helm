import SwiftUI

/// The teardown question, the stronger kill question, and the result (D-06). No flow logic: that lives in `TeardownModel`.
struct TeardownSheet: View {
    @ObservedObject var model: TeardownModel
    let onClose: () -> Void

    var body: some View {
        TeardownSheetContent(
            label: model.label, state: model.state,
            onConfirm: { Task { await model.confirm() } }, onConfirmKill: { Task { await model.confirmKill() } },
            onClose: onClose
        )
        // Closing in the middle of a run would drop the result.
        .interactiveDismissDisabled(TeardownSheetContent.isBusy(model.state))
    }
}

/// What the Teardown sheet draws, from plain data and actions, so a render test needs no model or script run.
struct TeardownSheetContent: View {
    let label: String
    let state: TeardownModel.State
    let onConfirm: () -> Void
    let onConfirmKill: () -> Void
    let onClose: () -> Void

    static func isBusy(_ state: TeardownModel.State) -> Bool {
        if case .running = state { return true }
        return false
    }

    var body: some View {
        KitSheetFrame(
            title: "Tear Down \(label)", width: SheetWidth.large, progress: progress,
            primaryTitle: primaryTitle, cancelTitle: isResult ? "Close" : "Cancel", cancelEnabled: !Self.isBusy(state),
            cancel: onClose, primary: isAskingKill ? onConfirmKill : onConfirm
        ) { content }
    }

    private var progress: String? {
        if case .running(let kill) = state { kill ? "Stopping the worker" : "Tearing down" } else { nil }
    }

    private var primaryTitle: String? {
        switch state {
        case .asking: "Tear Down"
        case .askingKill: "Stop Worker"
        default: nil
        }
    }

    private var isAskingKill: Bool {
        if case .askingKill = state { true } else { false }
    }

    private var isResult: Bool {
        if case .result = state { true } else { false }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .asking:
            SheetNote(text: "Tear down \(label)? The worker's window closes, the worktree and the branch are removed, and the remote branch is deleted.")
        case .running:
            EmptyView()
        case .askingKill(let output):
            SheetNote(text: "\(label) is not merged. Stop it anyway? The branch is kept as session/\(label)-orphaned-<time>, the worktree stays, and the worker is marked dead.")
            OutputArea(text: output)
        case .result(let outcome):
            Text(verbatim: "\(outcome.succeeded ? "Done" : "Failed"), exit \(outcome.status)")
                .kitType(.title).foregroundStyle(Ink.text)
            if let detail = outcome.detail { SheetNote(text: detail) }
            OutputArea(text: outcome.output)
        }
    }
}
