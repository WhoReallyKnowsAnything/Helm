import Foundation

/// What the teardown sheet shows (D-06). It asks once, then runs `--teardown`. If the script refuses with "not merged",
/// a second and stronger question offers `--kill`. Every step arrives as a closure, so tests use stubs and the blocking
/// ones run off the main actor. One run at a time: a Confirm while a run goes starts nothing.
@MainActor
final class TeardownModel: ObservableObject, Identifiable {
    /// `ContentView` presents the sheet with `.sheet(item:)`.
    let id = UUID()

    struct Outcome: Equatable {
        var succeeded: Bool
        /// True when the result is the kill route.
        var killed: Bool
        var status: Int32
        var output: String
        var detail: String?
    }

    enum State: Equatable {
        /// The first question.
        case asking
        case running(kill: Bool)
        /// The second, stronger question. `output` is the script's refusal.
        case askingKill(output: String)
        case result(Outcome)
    }

    @Published private(set) var state = State.asking

    let label: String
    private let captureEnvironment: @Sendable () throws -> [String: String]
    private let teardown: @Sendable (_ environment: [String: String]) -> MergeReview.Run
    private let kill: @Sendable (_ environment: [String: String]) -> MergeReview.Run
    /// Fires once at the first run and once at the kill run, so the view can close the worker's terminal (D-11).
    private let willRun: @MainActor () -> Void
    private var environment: [String: String] = [:]

    init(
        label: String,
        captureEnvironment: @escaping @Sendable () throws -> [String: String],
        teardown: @escaping @Sendable ([String: String]) -> MergeReview.Run,
        kill: @escaping @Sendable ([String: String]) -> MergeReview.Run,
        willRun: @escaping @MainActor () -> Void
    ) {
        self.label = label
        self.captureEnvironment = captureEnvironment
        self.teardown = teardown
        self.kill = kill
        self.willRun = willRun
    }

    /// The real steps for one worker: `folder` is the project's main checkout.
    convenience init(label: String, folder: String, willRun: @escaping @MainActor () -> Void) {
        self.init(
            label: label,
            captureEnvironment: { try MergeReview.environment() },
            teardown: { MergeReview.teardown(label: label, folder: folder, environment: $0) },
            kill: { MergeReview.kill(label: label, folder: folder, environment: $0) },
            willRun: willRun)
    }

    /// The first Confirm: runs `--teardown`. A "not merged" refusal moves to the second question and runs nothing more.
    func confirm() async {
        guard case .asking = state else { return }
        state = .running(kill: false)
        let capture = captureEnvironment
        switch await Task.detached(operation: { Result { try capture() } }).value {
        case .failure(let error):
            state = .result(Outcome(succeeded: false, killed: false, status: -1, output: "", detail: error.localizedDescription))
            return
        case .success(let captured): environment = captured
        }
        willRun()
        let teardown = self.teardown, environment = self.environment
        let run = await Task.detached(operation: { teardown(environment) }).value
        if let failure = run.failure {
            state = .result(Outcome(succeeded: false, killed: false, status: run.status, output: run.output, detail: failure.text))
            return
        }
        switch MergeReview.classifyTeardown(status: run.status, output: run.output) {
        case .done: state = .result(Outcome(succeeded: true, killed: false, status: run.status, output: run.output))
        case .notMerged: state = .askingKill(output: run.output)
        case .failed: state = .result(Outcome(succeeded: false, killed: false, status: run.status, output: run.output))
        }
    }

    /// The second Confirm: runs `--kill <label>` once. The branch is kept, so nothing is lost.
    func confirmKill() async {
        guard case .askingKill = state else { return }
        state = .running(kill: true)
        willRun()
        let kill = self.kill, environment = self.environment
        let run = await Task.detached(operation: { kill(environment) }).value
        let ok = run.failure == nil && run.status == 0
        let detail = run.failure?.text
            ?? (ok ? "The branch is kept as session/\(label)-orphaned-<epoch>, the worktree is kept and the worker is marked dead." : nil)
        state = .result(Outcome(succeeded: ok, killed: true, status: run.status, output: run.output, detail: detail))
    }
}
