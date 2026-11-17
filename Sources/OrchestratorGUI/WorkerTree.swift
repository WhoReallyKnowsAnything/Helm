import Foundation

struct WorkerTreeNode: Equatable {
    enum Kind: Equatable { case orchestrator, worker }

    let key: String
    let kind: Kind
    let title: String
    let taskTitle: String?
    /// nil for the orchestrator.
    let status: WorkerStatus?
}

struct WorkerTreeEdge: Equatable {
    enum Kind: Equatable { case hierarchy, dependency }

    /// Hierarchy: the parent. Dependency: the dependent.
    let from: String
    /// Hierarchy: the child. Dependency: the upstream.
    let to: String
    let kind: Kind
}

/// The `last_activity_at` of the block that a live hold already covered, by worker label (D-09).
/// The gate records `blocked` when a hold starts and nothing records an event when the user answers, so a row
/// stays `blocked` after Approve or Deny. A block whose `last_activity_at` is stored here belonged to a hold
/// that the user could answer, so it is not a new wait. A newer value is a new block.
struct BlockCover: Equatable {
    private var covered: [String: String] = [:]

    func lastActivityAt(of label: String) -> String? { covered[label] }

    /// For every label with at least 1 live hold, stores that label's current row value. A row with no value covers nothing.
    mutating func update(rows: [WorkerRow], holds: [GateHold]) {
        let live = Set(holds.filter { $0.state == .live }.map(\.label))
        for row in rows where live.contains(row.agentId) {
            covered[row.agentId] = row.lastActivityAt
        }
    }
}

/// The 2-level tree (D-14, D-15): the orchestrator, then every visible worker.
struct WorkerTree: Equatable {
    /// The orchestrator's `dashboard` row is not a worker row. Its node comes from the tmux row, so it exists
    /// without a database.
    static let orchestratorKey = "dashboard"

    let nodes: [WorkerTreeNode]
    let edges: [WorkerTreeEdge]

    /// `state` is nil when there is no worker data (no database, no sessions table, no access).
    /// `holds` and `cover` apply the cyan rule (D-09): only a live hold, or a database block that a live hold already
    /// covered, changes a status. Decided, tampered and ghost hold files never do, because hold files are untrusted (D-07).
    /// `log` is each node's out-log status, keyed by the orchestrator key `dashboard` and each worker's `agentId`.
    init(orchestratorTitle: String, state: WorkerState?, log: [String: SessionStatusStore.Entry], now: Date,
         holds: [GateHold] = [], cover: BlockCover = BlockCover(), deadLabels: Set<String> = []) {
        let waiting = Set(holds.filter { $0.state == .live }.map(\.label))
        let workers: [WorkerTreeNode] = (state?.rows ?? []).compactMap { row in
            WorkerStatusRules.status(of: row, lastWrite: log[row.agentId]?.modified, now: now,
                                     live: !deadLabels.contains(row.agentId)).map { status in
                var status = status
                if waiting.contains(row.agentId) {
                    status = .waiting
                } else if status == .waiting, let seen = row.lastActivityAt, cover.lastActivityAt(of: row.agentId) == seen {
                    status = .running
                }
                // A turn that ended (its `result` is the last turn event) means the worker waits for the user (D-02).
                if status == .running, log[row.agentId]?.fold.turnInProgress == false {
                    status = .waiting
                }
                return WorkerTreeNode(key: row.agentId, kind: .worker, title: row.agentId, taskTitle: row.taskTitle, status: status)
            }
        }
        nodes = [WorkerTreeNode(key: Self.orchestratorKey, kind: .orchestrator, title: orchestratorTitle, taskTitle: nil, status: nil)]
            + workers

        let visible = Set(workers.map(\.key))
        // No parent column exists (D-14): every visible worker hangs off the orchestrator.
        let hierarchy = workers.map { WorkerTreeEdge(from: Self.orchestratorKey, to: $0.key, kind: .hierarchy) }
        // A line to a hidden node disappears with it (D-15).
        let dependencies = (state?.dependencies ?? [])
            .filter { $0.dependent != $0.upstream && visible.contains($0.dependent) && visible.contains($0.upstream) }
            .map { WorkerTreeEdge(from: $0.dependent, to: $0.upstream, kind: .dependency) }
        edges = hierarchy + dependencies
    }

    /// For a screen that holds the read result. Only a loaded result gives a state.
    init(orchestratorTitle: String, result: WorkerRead?, log: [String: SessionStatusStore.Entry], now: Date,
         holds: [GateHold] = [], cover: BlockCover = BlockCover(), deadLabels: Set<String> = []) {
        var state: WorkerState?
        if case .loaded(let loaded) = result { state = loaded }
        self.init(orchestratorTitle: orchestratorTitle, state: state, log: log, now: now, holds: holds, cover: cover,
                  deadLabels: deadLabels)
    }

    /// How many workers wait on the user and how many run, from the same statuses the cards show.
    /// The orchestrator has no status. Finished and stalled workers count in neither.
    var counts: (waiting: Int, running: Int) {
        (nodes.filter { $0.status == .waiting }.count, nodes.filter { $0.status == .running }.count)
    }
}
