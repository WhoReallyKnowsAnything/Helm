import Foundation

/// The selected project's worker state (D-01). No timer: a read happens when the project changes,
/// on `retry()` and on every request from outside, and each result is compared before it is published.
@MainActor
final class WorkerStore: ObservableObject {
    /// The last good result. nil while no project is set or before its first read.
    @Published private(set) var result: WorkerRead?
    @Published private(set) var failure: String?

    private let makeSource: @Sendable (String) -> WorkerSource
    /// Owns the source: every read and close runs here, never on the main actor, so the busy timeout
    /// cannot block the UI.
    private let queue = DispatchQueue(label: "WorkerStore.read")
    private var project: String?
    private var source: WorkerSource?
    /// Turns each change of the database files into a read request (D-02). Released on re-point, which stops the stream.
    private var watcher: ProjectWatcher?
    /// Bumped on every re-point, so a read that finishes for the old project is dropped.
    private var generation = 0
    private var reading = false
    /// A request that arrived during a read. One more read runs after it, so no event is lost.
    private var readAgain = false

    init(makeSource: @escaping @Sendable (String) -> WorkerSource = { WorkerDatabase(project: $0) }) {
        self.makeSource = makeSource
    }

    /// Points the store at a project folder, or at nothing. The previous source is closed first.
    func point(at folder: String?) {
        guard folder != project else { return }
        generation += 1
        reading = false
        readAgain = false
        if let old = source { queue.async { old.close() } }
        project = folder
        source = folder.map(makeSource)
        watcher = folder.map { ProjectWatcher(project: $0) { [weak self] in Task { @MainActor in self?.requestRead() } } }
        if result != nil { result = nil }
        if failure != nil { failure = nil }
        requestRead()
    }

    /// Reopens the project's connection, so access granted in System Settings takes effect (D-10).
    func retry() {
        let folder = project
        point(at: nil)
        point(at: folder)
    }

    func requestRead() {
        guard let source else { return }
        if reading {
            readAgain = true
            return
        }
        reading = true
        let current = generation
        queue.async { [weak self] in
            let outcome = source.read()
            Task { @MainActor in self?.finish(outcome, generation: current) }
        }
    }

    private func finish(_ outcome: WorkerRead, generation done: Int) {
        guard done == generation else { return }
        reading = false
        if case .failed(let text) = outcome {
            if failure != text { failure = text }
        } else {
            if result != outcome { result = outcome }
            if failure != nil { failure = nil }
        }
        if readAgain {
            readAgain = false
            requestRead()
        }
    }
}
