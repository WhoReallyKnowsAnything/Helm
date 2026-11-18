import Combine
import Foundation

/// One sidebar project the alerts watch. `folder` is the path of its `dashboard` window (D-13 of phase 2).
struct AlertProject: Equatable {
    let id: String
    let folder: String
    let title: String
}

/// A worker node to select, set by a banner click and cleared by `ContentView`.
struct FocusRequest: Equatable {
    let projectId: String
    let label: String
}

/// Watches the worker rows and the gate holds of EVERY sidebar project (D-10), feeds an `AlertTracker` and hands
/// out its alerts and its count. No timer: a read happens when a project is added and on every file event.
/// It has its own watchers and does not reuse `HoldStore`, which follows the selected project only.
@MainActor
final class AlertStore: ObservableObject {
    /// One watched project. A removed or replaced entry is no longer in `entries`, which drops its late results.
    @MainActor private final class Entry {
        let project: AlertProject
        let source: WorkerSource
        /// Owns the source: every read and close runs here, never on the main actor.
        let queue = DispatchQueue(label: "AlertStore.read")
        var watchers: [ProjectWatcher] = []
        var reading = false
        /// A request that arrived during a read. One more read runs after it, so no event is lost.
        var readAgain = false
        /// The tmux window names of the project's session. nil until `follow` reports them (unknown counts live).
        var live: Set<String>?

        init(project: AlertProject, source: WorkerSource) {
            self.project = project
            self.source = source
        }
    }

    /// Live holds plus pane-blocked workers without a hold, over all projects (D-10).
    @Published private(set) var count = 0
    /// `count` split by project id, for the sidebar rows.
    @Published private(set) var counts: [String: Int] = [:]
    /// Set by a banner click. `ContentView` selects the node and clears it.
    @Published var pendingFocus: FocusRequest?

    private let makeSource: @Sendable (String) -> WorkerSource
    private let onAlert: (Alert) -> Void
    private let onCount: (Int) -> Void
    private var tracker = AlertTracker()
    private var entries: [String: Entry] = [:]
    private var subscription: AnyCancellable?
    private var lastProjects: [AlertProject]?

    /// Both closures run on the main actor. `onCount` runs only when the count changed.
    init(
        makeSource: @escaping @Sendable (String) -> WorkerSource = { WorkerDatabase(project: $0) },
        onAlert: @escaping (Alert) -> Void,
        onCount: @escaping (Int) -> Void
    ) {
        self.makeSource = makeSource
        self.onAlert = onAlert
        self.onCount = onCount
    }

    /// Follows the sidebar: the projects are the base sessions that have a `dashboard` window. The list is applied only when it changes.
    /// The subscription belongs to the store, so alerts keep running when the window closes.
    func follow(_ sessions: SessionStore) {
        subscription = sessions.$snapshot.sink { [weak self] snapshot in
            let projects = snapshot.rows.compactMap { row -> AlertProject? in
                guard let path = snapshot.windows.first(where: { $0.session == row.id && $0.name == "dashboard" })?.path else { return nil }
                return AlertProject(id: row.id, folder: path, title: row.title)
            }
            guard let self else { return }
            if projects != self.lastProjects {
                self.lastProjects = projects
                self.setProjects(projects)
            }
            // shortcut: window existence only, so a dead pane that tmux keeps counts as live until tmux drops it.
            for project in projects {
                let names = Set(snapshot.windows.filter { $0.session == project.id }.map(\.name))
                guard let entry = self.entries[project.id], entry.live != names else { continue }
                entry.live = names
                self.requestRead(entry)
            }
        }
    }

    /// Adds watchers for a new project and releases the watchers of a removed or changed one.
    func setProjects(_ projects: [AlertProject]) {
        let wanted = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, entry) in entries where wanted[id] != entry.project {
            entry.watchers = []
            let source = entry.source
            entry.queue.async { source.close() }
            entries[id] = nil
            tracker.remove(project: id)
        }
        for project in projects where entries[project.id] == nil {
            let entry = Entry(project: project, source: makeSource(project.folder))
            entries[project.id] = entry
            let ask: @Sendable () -> Void = { [weak self, weak entry] in
                Task { @MainActor in
                    if let self, let entry { self.requestRead(entry) }
                }
            }
            entry.watchers = [ProjectWatcher(project: project.folder, onEvent: ask), ProjectWatcher(holdsOf: project.folder, onEvent: ask)]
            requestRead(entry)
        }
        publishCount()
    }

    private func requestRead(_ entry: Entry) {
        guard entries[entry.project.id] === entry else { return }
        if entry.reading {
            entry.readAgain = true
            return
        }
        entry.reading = true
        let source = entry.source, folder = entry.project.folder
        entry.queue.async { [weak self] in
            // Rows first, then holds. The gate writes the `.pending` file before it marks the worker blocked, so a
            // blocked row seen after a hold read that found no hold is a real pane block. The reverse order could
            // read the hold folder first, then the block, and raise a false "blocked" banner just before the hold banner.
            let rows = source.read()
            let holds = GateHoldReader.read(project: folder)
            Task { @MainActor in self?.finish(entry, rows: rows, holds: holds) }
        }
    }

    private func finish(_ entry: Entry, rows: WorkerRead, holds: GateHoldRead) {
        guard entries[entry.project.id] === entry else { return }
        entry.reading = false
        defer {
            if entry.readAgain {
                entry.readAgain = false
                requestRead(entry)
            }
        }
        // An unreadable project keeps its previous data and feeds nothing, so it never looks like a quiet one that later wakes up with banners.
        let list: [WorkerRow]
        switch rows {
        case .loaded(let state): list = state.rows
        case .noDatabase, .noState: list = []
        case .permissionDenied, .failed: return
        }
        guard case .holds(let found) = holds else { return }
        let snapshot = AlertSnapshot(projectId: entry.project.id, projectTitle: entry.project.title, holds: found, rows: list,
                                     liveWindows: entry.live)
        for alert in tracker.ingest(snapshot) { onAlert(alert) }
        publishCount()
    }

    private func publishCount() {
        // Checked before the total: a count can move between projects and leave the total the same.
        if tracker.counts != counts { counts = tracker.counts }
        guard tracker.count != count else { return }
        count = tracker.count
        onCount(count)
    }
}
