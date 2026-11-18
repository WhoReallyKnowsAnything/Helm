import Foundation

/// The selected project's task-list file (D-12). No timer: a read happens when the project changes and on every
/// event for the file. A failed read keeps the last good list and shows a failure line beside it.
@MainActor
final class TaskListStore: ObservableObject {
    /// The last good list. Nil before the first good read, and after re-pointing.
    @Published private(set) var list: TaskList?
    @Published private(set) var failure: String?

    private let queue = DispatchQueue(label: "TaskListStore.read")
    private var project: String?
    private var watcher: ProjectWatcher?
    /// Bumped on every re-point, so a read that finishes for the old project is dropped.
    private var generation = 0
    private var reading = false
    /// A request that arrived during a read. One more read runs after it, so no event is lost.
    private var readAgain = false

    func point(at folder: String?) {
        guard folder != project else { return }
        generation += 1
        reading = false
        readAgain = false
        project = folder
        watcher = folder.map { ProjectWatcher(taskListOf: $0) { [weak self] in Task { @MainActor in self?.requestRead() } } }
        if list != nil { list = nil }
        if failure != nil { failure = nil }
        requestRead()
    }

    func requestRead() {
        guard let project else { return }
        if reading {
            readAgain = true
            return
        }
        reading = true
        let current = generation
        queue.async { [weak self] in
            let outcome = TaskListFile.read(project: project)
            Task { @MainActor in self?.finish(outcome, generation: current) }
        }
    }

    private func finish(_ outcome: TaskListRead, generation done: Int) {
        guard done == generation else { return }
        reading = false
        switch outcome {
        case .failed(let text):
            if failure != text { failure = text }
        case .list(let fresh):
            if list != fresh { list = fresh }
            if failure != nil { failure = nil }
        }
        if readAgain {
            readAgain = false
            requestRead()
        }
    }
}
