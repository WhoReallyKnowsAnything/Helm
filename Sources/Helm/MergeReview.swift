import Foundation

/// The pure part of running `merge-review.sh` (D-03, D-06): what a label may hold, and what a run's output means.
/// Every classification reads one combined output text.
enum MergeReview {
    /// A label becomes one argv element, so a leading `-` would read as an option. Checked before any process starts.
    static func isValidLabel(_ label: String) -> Bool {
        let alphanumeric = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard let first = label.first, alphanumeric.contains(first) else { return false }
        return label.allSatisfy { alphanumeric.contains($0) || ".-_".contains($0) }
    }

    enum MergeVerdict: Equatable {
        case merged
        /// The script ended in "Merge cancelled." (exit 0): nothing merged.
        case cancelled
        case failed(status: Int32)
    }

    enum TeardownVerdict: Equatable {
        case done
        /// The script refused: the branch is not merged. Offers the kill route (D-06).
        case notMerged
        case failed(status: Int32)
    }

    /// "Merged" needs exit 0 and the success marker for this label. The marker ends in ` → `, so `alpha` never matches `alp`.
    static func classifyMerge(label: String, status: Int32, output: String) -> MergeVerdict {
        guard status == 0 else { return .failed(status: status) }
        let marker = "✓ Merge complete: session/\(label) → "
        if output.contains("Merge cancelled.") { return .cancelled }
        return lines(output).contains(where: { $0.hasPrefix(marker) }) ? .merged : .failed(status: status)
    }

    static func classifyTeardown(status: Int32, output: String) -> TeardownVerdict {
        if status == 0 { return .done }
        return output.contains("is not merged into") ? .notMerged : .failed(status: status)
    }

    // MARK: runs

    static let script = OrchestratorPaths.orchestratorRepo + "/orchestration/merge-review.sh"

    enum Failure: Equatable {
        case invalidLabel(String)
        case didNotStart(String)
        case timedOut(seconds: Int)

        var text: String {
            switch self {
            case .invalidLabel(let label): return "The label \"\(label)\" is not safe to pass to a script. Nothing was run."
            case .didNotStart(let reason): return reason
            case .timedOut(let seconds):
                return "The run was stopped after \(seconds) seconds and may be half done. Check the project folder."
            }
        }
    }

    /// What one run came back with: the combined output, the exit status, and why it did not run to its end, if so.
    struct Run: Equatable {
        var output: String
        var status: Int32
        var failure: Failure?
    }

    /// The user's own shell environment as a dictionary, so the script finds git, sqlite3, tmux and gh.
    static func environment() throws -> [String: String] {
        var env = Dictionary(try EnvironmentCapture.capture().map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        if let socket = TmuxRunner.socket { env["ORCH_TMUX_SOCKET"] = socket }
        return env
    }

    /// Read-only: the diff stat, the commits and a conflict check.
    static func preview(
        label: String, folder: String, environment: [String: String], script: String = script, timeout: TimeInterval = 60
    ) -> Run {
        run(script, [label], label: label, folder: folder, environment: environment, timeout: timeout)
    }

    /// `y` and a newline on stdin: closed or empty stdin reads as "no" (D-02). Never `--yes`, which detaches teardown into a log.
    static func merge(
        label: String, folder: String, environment: [String: String], script: String = script, timeout: TimeInterval = 600
    ) -> Run {
        run(script, [label, "--merge"], label: label, folder: folder, environment: environment, input: "y\n", timeout: timeout)
    }

    static func teardown(
        label: String, folder: String, environment: [String: String], script: String = script, timeout: TimeInterval = 300
    ) -> Run {
        run(script, [label, "--teardown"], label: label, folder: folder, environment: environment, timeout: timeout)
    }

    /// Keeps the branch as `session/<label>-orphaned-<epoch>`, keeps the worktree and marks the row `dead` (D-06).
    static func kill(
        label: String, folder: String, environment: [String: String], script: String = HoldDecider.defaultScript,
        timeout: TimeInterval = 60
    ) -> Run {
        run(script, ["--kill", label], label: label, folder: folder, environment: environment, timeout: timeout)
    }

    /// Records the worker's `done` event, the only writer of it. The script finds the label's own worktree from the cwd,
    /// so the folder is the worker's worktree, not the main checkout. A missing worktree path runs nothing.
    static func markDone(
        label: String, worktree: String?, environment: [String: String], script: String = HoldDecider.defaultScript,
        timeout: TimeInterval = 60
    ) -> Run {
        guard let worktree, !worktree.isEmpty else {
            return Run(output: "", status: -1, failure: .didNotStart("The worker has no worktree path. Nothing was run."))
        }
        return run(script, ["--mark-done", label], label: label, folder: worktree, environment: environment, timeout: timeout)
    }

    /// A direct child with an argv array, never a shell. The folder is the project's main checkout: the script picks its project from the cwd (D-01).
    private static func run(
        _ script: String, _ arguments: [String], label: String, folder: String, environment: [String: String],
        input: String? = nil, timeout: TimeInterval
    ) -> Run {
        guard isValidLabel(label) else { return Run(output: "", status: -1, failure: .invalidLabel(label)) }
        let result = ProcessRunner.run(
            script, arguments, environment: environment, workingFolder: folder, input: input, mergeStderr: true, timeout: timeout)
        if let reason = result.startError { return Run(output: result.stdout, status: result.status, failure: .didNotStart(reason)) }
        if result.timedOut {
            return Run(output: result.stdout, status: result.status, failure: .timedOut(seconds: Int(timeout.rounded(.up))))
        }
        return Run(output: result.stdout, status: result.status, failure: nil)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init)
    }
}
