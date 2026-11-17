import Foundation

/// One project waiting for the user's yes or no on the per-project Close.
struct CloseRequest: Equatable {
    let id: String
    let title: String
    let folder: String
    /// Worker windows in the project's session. `--teardown-project` kills them with the base session.
    let liveWorkers: Int

    var message: String {
        if liveWorkers == 0 { return "This stops its orchestrator session. Its worktrees and branches stay." }
        let workers = liveWorkers == 1 ? "1 live worker stops" : "\(liveWorkers) live workers stop"
        return "This stops its orchestrator session and \(workers) too. Their worktrees and branches stay until a worker teardown."
    }
}

/// The sidebar Close flow: ask, then stop one project. The teardown arrives as a closure and this model
/// makes no tmux call of its own (same pattern as `QuitModel`).
@MainActor
final class CloseModel: ObservableObject {
    @Published private(set) var pending: CloseRequest?
    @Published private(set) var failure: QuitFailure?
    private let teardown: @Sendable (_ sessionId: String, _ folder: String) async throws -> Void

    /// Called with the project id once the teardown succeeded, so the open-project list forgets it.
    private let forget: @MainActor (_ sessionId: String) -> Void

    init(
        teardown: @escaping @Sendable (String, String) async throws -> Void,
        forget: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.teardown = teardown
        self.forget = forget
    }

    func ask(_ row: SessionRow, in snapshot: TmuxSnapshot) {
        let windows = snapshot.windows.filter { $0.session == row.id }
        let folder = windows.first { $0.name == "dashboard" }?.path ?? ""
        pending = CloseRequest(
            id: row.id, title: row.title, folder: folder,
            liveWorkers: windows.filter { $0.name != "dashboard" }.count)
    }

    func cancel() { pending = nil }

    func take() -> CloseRequest? { defer { pending = nil }; return pending }

    func dismissFailure() { failure = nil }

    /// Stops the project in `request` (from `take()`). Returns its id on success, nil on cancel or failure (the reason is in `failure`).
    func confirm(_ request: CloseRequest?) async -> String? {
        guard let request else { return nil }
        do {
            try await teardown(request.id, request.folder)
            forget(request.id)
            return request.id
        } catch {
            let named = request.title == request.id ? request.title : "\(request.title) (session \(request.id))"
            failure = QuitFailure(title: named, reason: error.localizedDescription)
            return nil
        }
    }
}
