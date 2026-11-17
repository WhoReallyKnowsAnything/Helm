import Foundation

/// Which out logs the request store follows: the selected project's, plus every other open project's workers.
enum RequestSessions {
    /// The selected project. A root session follows the global dashboard log, and its workers when its state is loaded.
    static func selected(isRoot: Bool, state: WorkerState?, live: (WorkerRow) -> Bool,
                         home: String = NSHomeDirectory()) -> [RequestStore.Session] {
        var sessions: [RequestStore.Session] = []
        if isRoot {
            let paths = WorkerState.rootDashboardPaths(home: home)
            sessions.append(.init(nodeKey: WorkerTree.orchestratorKey, outPath: paths.out, inboxPath: paths.inbox, live: true))
        } else if let out = state?.dashboardOutPath, let inbox = state?.dashboardInboxPath {
            sessions.append(.init(nodeKey: WorkerTree.orchestratorKey, outPath: out, inboxPath: inbox, live: true))
        }
        for row in state?.rows ?? [] {
            guard let out = row.outPath, let inbox = row.inboxPath else { continue }
            sessions.append(.init(nodeKey: row.agentId, outPath: out, inboxPath: inbox, live: live(row)))
        }
        return sessions
    }

    /// Everything the store follows: the selected project (when one is selected and loaded, or a root) plus the other open projects.
    static func all(hasSelection: Bool, isRoot: Bool, state: WorkerState?, live: (WorkerRow) -> Bool,
                    states: [String: WorkerState], folder: String?, home: String = NSHomeDirectory()) -> [RequestStore.Session] {
        let own = hasSelection && (isRoot || state != nil)
            ? selected(isRoot: isRoot, state: state, live: live, home: home) : []
        return own + others(states, excluding: folder)
    }

    /// Workers of the other open projects, keyed by folder so agent ids cannot collide. They are never answerable here.
    static func others(_ states: [String: WorkerState], excluding folder: String?) -> [RequestStore.Session] {
        states.keys.sorted().filter { $0 != folder }.flatMap { project in
            (states[project]?.rows ?? []).compactMap { row -> RequestStore.Session? in
                guard let out = row.outPath, let inbox = row.inboxPath else { return nil }
                return .init(nodeKey: project + "|" + row.agentId, outPath: out, inboxPath: inbox, live: false, project: project)
            }
        }
    }
}
