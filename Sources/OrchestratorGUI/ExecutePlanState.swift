import Foundation

/// The state of one plan on the execute screen (D-07) and whether it shows as a failure (D-11).
/// Pure: the caller supplies the `replay-check` status lines and the worker's liveness.
enum ExecutePlanState: Equatable {
    case waiting, running, done, partial
    /// The text after `PLAN CHECKPOINT:`, kept as written.
    case checkpoint(String)

    struct Result: Equatable {
        var state: ExecutePlanState
        var failure: Bool
    }

    private static let complete = "PLAN COMPLETE"
    private static let checkpointPrefix = "PLAN CHECKPOINT:"

    /// A checkpoint type takes an answer only when it is exactly one of these four (D-10). `suite-red` and any other text take none.
    static func takesAnswer(_ type: String) -> Bool {
        ["structural", "human-verify", "decision", "blocked"].contains(type)
    }

    /// `statuses` maps plan file to its report's first line, with no entry for a plan without a report.
    /// A no-report plan runs only when dispatched: with one wave (a parallel batch, D-02) every plan; with several waves
    /// (a sequential run) only the lowest-numbered incomplete plan.
    static func resolve(file: String, waves: [[String]], statuses: [String: String], live: Bool) -> Result {
        guard let status = statuses[file] else {
            // One wave of plans is a parallel batch (D-02): all dispatched together. Several waves mean the coordinator
            // ran sequentially (overlap or depends_on): only the lowest-numbered incomplete plan is in progress.
            let firstIncomplete = waves.flatMap { $0 }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                .first { statuses[$0] != complete }
            let dispatched = waves.count == 1 || file == firstIncomplete
            return Result(state: live && dispatched ? .running : .waiting, failure: false)
        }
        if status == complete { return Result(state: .done, failure: false) }
        if status.hasPrefix(checkpointPrefix) {
            let type = String(status.dropFirst(checkpointPrefix.count)).trimmingCharacters(in: .whitespaces)
            return Result(state: .checkpoint(type), failure: !live || type == "blocked")
        }
        // PLAN PARTIAL, or a first line this app does not know: the executor writes PARTIAL until complete.
        return live ? Result(state: .running, failure: false) : Result(state: .partial, failure: true)
    }
}
