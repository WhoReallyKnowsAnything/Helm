import Foundation

/// The pull request of the selected worker (D-15). A lookup runs when a worker is selected and when `refresh()` is
/// called. There is no timer and no file watcher. The lookup blocks, so it runs off the main actor.
@MainActor
final class PullRequestStore: ObservableObject {
    enum State: Equatable {
        case unselected
        case loading
        /// `nil` means the worker has no pull request.
        case loaded(PullRequest?)
        case failed(String)
    }

    typealias Lookup = @Sendable () -> PullRequestLookupResult

    @Published private(set) var state = State.unselected

    private var lookup: Lookup?
    /// Bumped on every select and clear, so a result for a worker that is no longer selected is dropped.
    private var generation = 0
    private var running = false
    /// A refresh that arrived during a lookup. One more lookup runs after it, whatever the count of requests.
    private var refreshAgain = false

    /// `lookup` is already bound to this worker. A new selection shows loading until its own result arrives.
    func select(lookup: @escaping Lookup) {
        generation += 1
        self.lookup = lookup
        refreshAgain = false
        start()
    }

    func refresh() {
        guard lookup != nil else { return }
        if running { refreshAgain = true } else { start() }
    }

    func clear() {
        generation += 1
        lookup = nil
        running = false
        refreshAgain = false
        state = .unselected
    }

    private func start() {
        guard let lookup else { return }
        running = true
        state = .loading
        let started = generation
        Task {
            // The lookup blocks, so it runs on a GCD thread. Blocking a Swift concurrency pool thread can starve other tasks.
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<PullRequestLookupResult, Never>) in
                DispatchQueue.global().async { continuation.resume(returning: lookup()) }
            }
            finish(result, started: started)
        }
    }

    private func finish(_ result: PullRequestLookupResult, started: Int) {
        guard started == generation else { return }
        running = false
        if refreshAgain {
            refreshAgain = false
            start()
            return
        }
        switch result {
        case .noPullRequest: state = .loaded(nil)
        case .found(let pullRequest): state = .loaded(pullRequest)
        case .failed(let text): state = .failed(text)
        }
    }
}
