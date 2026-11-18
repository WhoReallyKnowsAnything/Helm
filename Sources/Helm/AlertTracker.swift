import Foundation

/// What one project showed at one read: its classified holds and its worker rows.
struct AlertSnapshot {
    let projectId: String
    let projectTitle: String
    let holds: [GateHold]
    let rows: [WorkerRow]
    /// The tmux window names of this project. nil means unknown, so every row counts live.
    var liveWindows: Set<String>? = nil
}

/// One thing the user should hear about (D-15). `key` is the dedupe key, and the banner identifier.
struct Alert: Equatable {
    enum Kind: Equatable { case hold, blocked, finished }

    let kind: Kind
    let projectId: String
    let projectTitle: String
    let label: String
    let key: String
    /// The cleaned op text (`GateHold.command`). Only a hold alert has one.
    let command: String?
}

/// Decides what raises a banner and what the Dock badge counts (D-10, D-15). Pure: no clock, no process, no system call.
/// Each project's first snapshot is its baseline and raises nothing, so a project that is already busy when the app
/// starts, or that joins the sidebar later, stays quiet. Removing a project drops its share and its baseline.
struct AlertTracker {
    private struct Entry {
        /// The blocks that a live hold already covered (D-09).
        var cover = BlockCover()
        /// Pane-blocked labels of the previous snapshot.
        var blocked: Set<String> = []
        /// Every hold id that has been seen, so a hold that disappears and returns raises once.
        var holds: Set<String> = []
        /// Every finished key that has been seen.
        var finished: Set<String> = []
        var count = 0
    }

    private var entries: [String: Entry] = [:]

    /// Live holds plus pane-blocked workers without a live hold, over all projects the tracker has.
    var count: Int { entries.values.reduce(0) { $0 + $1.count } }
    /// The same count split by project id: the share each sidebar row shows.
    var counts: [String: Int] { entries.mapValues(\.count) }

    mutating func remove(project id: String) { entries[id] = nil }

    /// Returns the alerts that this snapshot raises.
    mutating func ingest(_ snapshot: AlertSnapshot) -> [Alert] {
        let baseline = entries[snapshot.projectId] == nil
        var entry = entries[snapshot.projectId] ?? Entry()
        entry.cover.update(rows: snapshot.rows, holds: snapshot.holds)

        // Decided, tampered and ghost files never count: a worker could write them to hide its wait (D-07).
        let live = snapshot.holds.filter { $0.state == .live }
        let liveLabels = Set(live.map(\.label))
        let blocked = snapshot.rows.filter { row in
            WorkerStatusRules.status(of: row, lastWrite: nil, now: Date(), live: snapshot.liveWindows?.contains(row.agentId)) == .waiting
                && !liveLabels.contains(row.agentId)
                && !(row.lastActivityAt.map { entry.cover.lastActivityAt(of: row.agentId) == $0 } ?? false)
        }
        // D-15 calls a worker finished when `status` is running and `last_event` is done.
        let finished = snapshot.rows.filter { $0.status == "running" && $0.lastEvent == "done" }

        var alerts: [Alert] = []
        func make(_ kind: Alert.Kind, _ label: String, _ key: String, command: String? = nil) {
            alerts.append(Alert(kind: kind, projectId: snapshot.projectId, projectTitle: snapshot.projectTitle,
                                label: label, key: key, command: command))
        }
        let blockedLabels = Set(blocked.map(\.agentId))
        if !baseline {
            for hold in live where !entry.holds.contains(hold.id) {
                make(.hold, hold.label, "hold:\(snapshot.projectId):\(hold.id)", command: hold.command)
            }
            for row in blocked where !entry.blocked.contains(row.agentId) {
                make(.blocked, row.agentId, "blocked:\(snapshot.projectId):\(row.agentId):\(row.lastActivityAt ?? "")")
            }
            for row in finished where !entry.finished.contains(Self.finishedKey(row)) {
                make(.finished, row.agentId, "finished:\(snapshot.projectId):\(Self.finishedKey(row))")
            }
        }
        entry.holds.formUnion(live.map(\.id))
        entry.finished.formUnion(finished.map(Self.finishedKey))
        entry.blocked = blockedLabels
        entry.count = live.count + blockedLabels.count
        entries[snapshot.projectId] = entry
        return alerts
    }

    private static func finishedKey(_ row: WorkerRow) -> String { "\(row.agentId):\(row.lastActivityAt ?? "")" }
}
