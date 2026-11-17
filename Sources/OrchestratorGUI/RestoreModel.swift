import Foundation

/// The per-project Restore press (D-02, D-03). Its steps arrive as closures, and it starts nothing in `init`:
/// no timer and no observer, so a restore cannot begin without `press`.
@MainActor
final class RestoreModel: ObservableObject {
    /// The id of the project whose restore runs now, so its row can disable the button.
    @Published private(set) var running: String?
    @Published private(set) var failure: QuitFailure?
    /// The `skipped <label>: <reason>` lines of a restore that exited 0, one per line.
    @Published private(set) var notice: QuitFailure?
    static let noticeLimit = 10
    private let capture: @Sendable () throws -> String
    private let restore: @Sendable (_ folder: String, _ envText: String) async throws -> RestoreResult
    private let refresh: @MainActor () async -> Void

    init(
        capture: @escaping @Sendable () throws -> String,
        restore: @escaping @Sendable (String, String) async throws -> RestoreResult,
        refresh: @escaping @MainActor () async -> Void
    ) {
        self.capture = capture
        self.restore = restore
        self.refresh = refresh
    }

    func dismissFailure() { failure = nil }
    func dismissNotice() { notice = nil }

    func press(_ project: OpenProject) async {
        guard running == nil else { return }
        running = project.id
        defer { running = nil }
        let capture = capture, restore = restore
        do {
            let envText = try await Task.detached { try capture() }.value
            let result = try await restore(project.folder, envText)
            if !result.skipped.isEmpty {
                // Output order is oldest first, so the last lines are the most recent. A tall alert pushes its button off screen.
                let hidden = max(0, result.skipped.count - Self.noticeLimit)
                let lines = (hidden > 0 ? ["and \(hidden) more"] : []) + result.skipped.suffix(Self.noticeLimit)
                notice = QuitFailure(
                    title: "Some workers of \(project.title) were not resumed", reason: lines.joined(separator: "\n"))
            }
            await refresh()
        } catch {
            failure = QuitFailure(title: project.title, reason: error.localizedDescription)
        }
    }
}
