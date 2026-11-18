import Foundation

/// What a visible worker shows (D-03 to D-06). The raw values are the display phrases.
enum WorkerStatus: String, Equatable {
    case running
    case waiting = "waiting on you"
    case stalled
    case finished
    case dead = "dead worker"
}

enum WorkerStatusRules {
    /// A running session whose out log was last written longer ago than this is stalled (D-03, D-07).
    static let stallSeconds = 600

    /// nil means hidden. Precedence: "waiting on you" before "finished" before "stalled", because the user
    /// must act even when the log is silent, and a finished worker is idle by nature. The app only hides
    /// rows and never deletes them (D-06). It reads no clock: the caller passes `now`.
    /// `lastWrite` is the out log's modification time; nil (no log) is never stalled (D-08).
    /// `live` is whether the worker's process exists; nil (unknown) counts as live. A finished row has no process by
    /// design. A running, blocked or stalled row with no process and past `WorkflowOverlay.startingSeconds` is `.dead`.
    static func status(of row: WorkerRow, lastWrite: Date?, now: Date, live: Bool? = nil) -> WorkerStatus? {
        if row.status == "merged" || row.status == "dead" { return nil }
        if row.status == "done" || (row.status == "running" && row.lastEvent == "done") { return .finished }
        if live == false, ["running", "blocked", "stalled"].contains(row.status),
           WorkflowOverlay.age(of: row.createdAt, now: now).map({ $0 >= WorkflowOverlay.startingSeconds }) ?? true {
            return .dead
        }
        if row.status == "blocked" || (row.status == "running" && row.lastEvent == "blocked") { return .waiting }
        if row.status == "stalled" { return .stalled }
        if row.status == "running", let lastWrite, now.timeIntervalSince(lastWrite) > Double(stallSeconds) {
            return .stalled
        }
        return .running
    }
}
