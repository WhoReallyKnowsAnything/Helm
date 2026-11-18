import Foundation

/// The G3 verdict for the selected worker. No timer: a check runs on `point` (a new selection or a changed row), on
/// `recheck`, and on a change to the worktree's UAT.md while the worktree exists. A stale run never publishes.
@MainActor
final class UATGateStore: ObservableObject {
    @Published private(set) var verdict = UATGate.Verdict.notGated

    private let check: @Sendable (_ project: String, _ row: WorkerRow) -> UATGate.Verdict
    private var project: String?
    private var row: WorkerRow?
    private var watcher: ProjectWatcher?
    private var generation = 0

    init(check: @escaping @Sendable (String, WorkerRow) -> UATGate.Verdict = { UATGateCheck().run(project: $0, row: $1) }) {
        self.check = check
    }

    /// The confirmation text for a complete UAT with skipped items (D-08).
    nonisolated static func skippedConfirmation(_ count: Int) -> String {
        count == 1 ? "1 item was skipped. Merge anyway?" : "\(count) items were skipped. Merge anyway?"
    }

    /// The verdict the strip and the merge routes use: allowed for a label the override store granted (D-09), else the check's.
    func effective(granted: Set<String>) -> UATGate.Verdict {
        if let row, granted.contains(row.agentId) { return .allowed }
        return verdict
    }

    /// Points the store at the selected worker, or clears it when `row` is nil. The same project and row do nothing.
    func point(project: String?, row: WorkerRow?) {
        guard project != self.project || row != self.row else { return }
        self.project = project
        self.row = row
        watcher = nil
        guard let project, let row, let phase = UATGate.phase(ofLabel: row.agentId) else {
            generation += 1
            publish(.notGated)
            return
        }
        if let folder = UATScreenLoader.watchFolder(project: project, phase: phase, worktree: row.worktreePath) {
            watcher = ProjectWatcher(uatIn: folder, onEvent: { [weak self] in Task { @MainActor in self?.recheck() } })
        }
        recheck()
    }

    /// Runs the check again. A label that is not gated publishes `notGated` and runs nothing.
    func recheck() {
        generation += 1
        let current = generation
        guard let project, let row, UATGate.phase(ofLabel: row.agentId) != nil else {
            publish(.notGated)
            return
        }
        publish(.checking)
        let check = check
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = check(project, row)
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.publish(result)
            }
        }
    }

    private func publish(_ new: UATGate.Verdict) {
        if new != verdict { verdict = new }
    }
}
