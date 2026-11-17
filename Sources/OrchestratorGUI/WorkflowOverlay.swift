import Foundation

/// What a stage worker for one phase shows on the board (plan 3). Pure: rows, live labels and the clock come in.
/// Phases 3-5 read the label and `State`, so neither changes.
struct WorkflowOverlay: Equatable {
    enum State: Equatable {
        case running, waitingForMerge, dead

        var holdText: String {
            switch self {
            case .waitingForMerge: return "waiting for merge"
            case .running: return "running"
            case .dead: return "dead worker"
            }
        }

        /// waitingForMerge, then running, then dead.
        fileprivate var precedence: Int {
            switch self {
            case .waitingForMerge: return 3
            case .running: return 2
            case .dead: return 1
            }
        }
    }

    var stage: WorkflowGates.Stage
    var state: State
    /// The worker label, `cad-<stage>-p<N>`.
    var label: String
    /// A live AskUserQuestion of a screen-stage worker is pending (D-02). Display text only; `state` is unchanged.
    var questionWaiting = false
    /// A finished plan worker whose worktree holds plan files (D-05). Display text only; `state` is unchanged.
    var planReady = false

    var text: String {
        switch state {
        case .waitingForMerge: return planReady ? "Plan ready for review" : "waiting for merge"
        case .dead: return "dead worker"
        case .running:
            if questionWaiting { return "question waiting" }
            return stage == .execute ? "executing" : "\(stage.rawValue) running"
        }
    }

    /// A row younger than this with no live process is a starting worker: the row is written before the window.
    static let startingSeconds: TimeInterval = 10
    static let stages: [WorkflowGates.Stage] = [.context, .plan, .execute, .verify, .milestone]

    /// `created_at` is SQLite `CURRENT_TIMESTAMP`: UTC, `yyyy-MM-dd HH:mm:ss`.
    static func age(of createdAt: String?, now: Date) -> TimeInterval? {
        guard let createdAt else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format.date(from: createdAt).map { now.timeIntervalSince($0) }
    }

    /// The state of one row, or nil for none (merged, dead). A missing or unreadable `created_at` counts as old.
    static func state(of row: WorkerRow, live: Bool, now: Date) -> State? {
        switch WorkerStatusRules.status(of: row, lastWrite: nil, now: now) {
        case nil: return nil
        case .finished: return .waitingForMerge
        default:
            if live { return .running }
            let young = age(of: row.createdAt, now: now).map { $0 < startingSeconds } ?? false
            return young ? .running : .dead
        }
    }

    /// The state of any one worker label (the stage rules, for `cad-config` too), or nil when it holds nothing.
    static func heldState(label: String, rows: [WorkerRow], liveLabels: Set<String>, now: Date) -> State? {
        var best: State?
        for row in rows where row.agentId == label {
            guard let state = state(of: row, live: liveLabels.contains(label), now: now) else { continue }
            if state.precedence > (best?.precedence ?? 0) { best = state }
        }
        return best
    }

    /// The one overlay for `phase`, or nil. Labels are matched exactly, so phase 1 never reads `cad-execute-p1-1`.
    static func derive(phase: String, rows: [WorkerRow], liveLabels: Set<String>, now: Date) -> WorkflowOverlay? {
        var best: WorkflowOverlay?
        for stage in stages {
            let label = WorkflowDispatch.label(stage: stage, phase: phase)
            var found = false
            for row in rows where row.agentId == label {
                guard let state = state(of: row, live: liveLabels.contains(label), now: now) else { continue }
                found = true
                if state.precedence > (best?.state.precedence ?? 0) {
                    best = WorkflowOverlay(stage: stage, state: state, label: label)
                }
            }
            // A live window with no row yet (not loaded, or hidden) still holds the phase.
            if !found, liveLabels.contains(label), State.running.precedence > (best?.state.precedence ?? 0) {
                best = WorkflowOverlay(stage: stage, state: .running, label: label)
            }
        }
        return best
    }
}
