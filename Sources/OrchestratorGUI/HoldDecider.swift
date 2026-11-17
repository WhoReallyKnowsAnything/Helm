import Foundation

enum HoldChoice: String {
    case allow, deny
}

/// What one `--gate-decide` run came back with (D-04). `delivered` means the decision file is written, not that the worker acted.
enum HoldDecision: Equatable {
    case delivered
    /// The hold is gone or no longer waiting. Not an error.
    case alreadyDecided
    case failed(String)
}

/// The one place that answers a hold (D-04). The app writes no `.decision` file itself: it runs the
/// orchestrator's `--gate-decide` as a direct child, with an argv array and never a shell.
enum HoldDecider {
    static let defaultScript = OrchestratorPaths.orchestratorRepo + "/orchestration/lib/dispatch-task.sh"
    static let timeout: TimeInterval = 10

    /// The 2 refusals that mean the hold ended before the answer arrived.
    private static let gone = ["no pending hold for that tool_use_id", "the hold is no longer waiting"]

    /// Built from scratch, never from the app's own environment: the script refuses a caller that has a
    /// non-empty `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID`, and an app started from a Claude Code shell carries both.
    static func environment(folder: String) -> [String: String] {
        var env = TmuxRunner.environment()
        env["ORCH_PROJECT_ROOT"] = folder
        return env
    }

    /// Blocks by design; callers run it off the main actor. `script` and `timeout` are parameters for tests (D-08).
    static func decide(
        label: String, id: String, choice: HoldChoice, hash: String, folder: String,
        script: String = defaultScript, timeout: TimeInterval = HoldDecider.timeout
    ) -> HoldDecision {
        let result = ProcessRunner.run(
            script, ["--gate-decide", label, id, choice.rawValue, hash],
            environment: environment(folder: folder), workingFolder: folder, timeout: timeout)
        if let error = result.startError { return .failed(error) }
        if result.timedOut { return .failed("Deciding took more than \(Int(timeout.rounded(.up))) seconds.") }
        if result.status == 0 { return .delivered }
        let line = lastLine(result.stderr) ?? lastLine(result.stdout) ?? "exit code \(result.status)"
        return gone.contains { line.contains($0) } ? .alreadyDecided : .failed(line)
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
