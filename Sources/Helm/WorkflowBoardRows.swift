import Foundation

/// What the board row shows, derived from values the board already has. Pure: no I/O, no state.
enum WorkflowBoardRows {
    /// "N of M phases done". N counts board rows shown as done. M is the larger of `status.total` and the row count,
    /// so N can never exceed M. CONTEXT leaves the reading of "N of M" open: this file reads it as done over total.
    static func progress(_ board: WorkflowBoard) -> String {
        let done = board.rows.filter { $0.display == .stage(.done) }.count
        let total = max(board.status?.total ?? 0, board.rows.count)
        return "\(done) of \(total) phases done"
    }

    /// The live holds of one phase row. Exact label equality, never label parsing, so phase 1 never reads `cad-execute-p1-1`.
    static func holds(_ holds: [GateHold], phase: String) -> [GateHold] {
        let labels = Set(WorkflowOverlay.stages.map { WorkflowDispatch.label(stage: $0, phase: phase) })
        return holds.filter { $0.state == .live && labels.contains($0.label) }
    }

    /// Splits chips into the ones on a phase row (phase-scoped, row found) and the Suggested menu (all others), each in order.
    /// A phase-scoped chip with no matching row stays in the menu, so no chip is dropped.
    static func splitChips(_ chips: [CadenceChip], rows: [WorkflowBoard.Row]) -> (onRows: [String: [CadenceChip]], menu: [CadenceChip]) {
        let numbers = Set(rows.map(\.n))
        var onRows: [String: [CadenceChip]] = [:]
        var menu: [CadenceChip] = []
        for chip in chips {
            let shape = WorkflowDispatch.chipTable.first { $0.skill == chip.skill }?.shape
            if (shape == .phase || shape == .decisionReview), let phase = chip.phase, numbers.contains(phase) {
                onRows[phase, default: []].append(chip)
            } else {
                menu.append(chip)
            }
        }
        return (onRows, menu)
    }

    /// The status mark of one overlay: its own text and the status colour. A question or a finished worker waits on the user.
    static func mark(_ overlay: WorkflowOverlay) -> (status: WorkerStatus, text: String) {
        switch overlay.state {
        case .dead: return (.dead, overlay.text)
        case .waitingForMerge: return (.waiting, overlay.text)
        case .running: return (overlay.questionWaiting ? .waiting : .running, overlay.text)
        }
    }
}
