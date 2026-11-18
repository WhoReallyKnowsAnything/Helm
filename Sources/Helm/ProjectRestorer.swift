import Foundation

/// What `--resume` reported: the lines that start `resumed ` and `skipped `, verbatim.
struct RestoreResult: Equatable {
    var resumed: [String] = []
    var skipped: [String] = []
}

/// Restores one project (D-02): start its base session through the launcher, then run `dispatch-task.sh --resume`.
/// `--resume` refuses without the base session, so the order is forced. Nothing here runs without a Restore press (D-03).
enum ProjectRestorer {
    static let timeout: TimeInterval = 60

    /// Blocks by design; callers run it off the main actor (`restoreOffMain`). The scripts are parameters for tests.
    static func restore(
        folder: String, envText: String,
        launcher: String = ProjectLauncher.launcherPath, dispatchScript: String = ProjectTeardown.defaultScript,
        timeout: TimeInterval = timeout
    ) throws -> RestoreResult {
        guard !folder.isEmpty else { throw SessionCheckFailure(reason: "This project has no folder, so nothing was restored.") }
        // A thrown LaunchFailure propagates, so --resume never runs without the base session.
        _ = try ProjectLauncher.launch(folder: folder, envText: envText, launcher: launcher, timeout: timeout)
        var environment = TmuxRunner.environment()
        environment["ORCH_PROJECT_ROOT"] = folder
        let result = ProcessRunner.run(
            dispatchScript, ["--resume"], environment: environment, workingFolder: folder, timeout: timeout)
        if result.timedOut || result.failedToStart || result.status != 0 {
            let detail = [result.startError ?? "", result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit code \(result.status)"
            throw SessionCheckFailure(reason: result.timedOut ? "Resuming timed out after \(Int(timeout)) seconds. \(detail)" : detail)
        }
        let lines = result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return RestoreResult(
            resumed: lines.filter { $0.hasPrefix("resumed ") }, skipped: lines.filter { $0.hasPrefix("skipped ") })
    }

    static func restoreOffMain(folder: String, envText: String) async throws -> RestoreResult {
        try await Task.detached { try restore(folder: folder, envText: envText) }.value
    }
}
