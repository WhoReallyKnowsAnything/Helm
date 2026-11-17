import Combine
import Foundation

/// The out-log paths of every open project (D-15): the usage panel reads the newest `rate_limit_event` across all of
/// them, not only the selected project's. One `WorkerStore` per folder reads the path fields on file events, so there
/// is no timer and no second path-building code.
@MainActor
final class OpenProjectLogs: ObservableObject {
    /// Every worker row's out-log path and each `dashboard` path, over all followed projects.
    @Published private(set) var paths: Set<String> = []
    /// The loaded worker state of each open project, by folder. The request store follows the workers in it.
    @Published private(set) var states: [String: WorkerState] = [:]

    private let makeSource: @Sendable (String) -> WorkerSource
    private var stores: [String: (store: WorkerStore, subscription: AnyCancellable)] = [:]

    init(makeSource: @escaping @Sendable (String) -> WorkerSource = { WorkerDatabase(project: $0) }) {
        self.makeSource = makeSource
    }

    /// Adds stores for new folders and drops the stores of folders that left.
    func follow(_ folders: [String]) {
        let wanted = Set(folders)
        for folder in stores.keys where !wanted.contains(folder) {
            stores[folder]?.store.point(at: nil)
            stores[folder] = nil
        }
        for folder in wanted where stores[folder] == nil {
            let store = WorkerStore(makeSource: makeSource)
            let subscription = store.$result.sink { [weak self] _ in
                // `$result` fires before the property is set, so the union is rebuilt on the next main-actor turn.
                Task { @MainActor in self?.rebuild() }
            }
            stores[folder] = (store, subscription)
            store.point(at: folder)
        }
        rebuild()
    }

    private func rebuild() {
        var union: Set<String> = []
        var loaded: [String: WorkerState] = [:]
        for (folder, entry) in stores {
            guard case .loaded(let state) = entry.store.result else { continue }
            loaded[folder] = state
            if let out = state.dashboardOutPath { union.insert(out) }
            for row in state.rows { if let out = row.outPath { union.insert(out) } }
        }
        if union != paths { paths = union }
        if loaded != states { states = loaded }
    }
}
