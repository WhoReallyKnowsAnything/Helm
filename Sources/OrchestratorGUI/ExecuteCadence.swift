import Foundation

/// Cadence's own answers for the execute screen: `planning.mjs replay-check` (one status line per plan report) and
/// `planning.mjs plan-overlap` (the waves). Both are read-only. The app adds no field of its own (D-03).
enum ExecuteCadence {
    struct Plan: Equatable {
        var file: String
        var k: Int
        var exists: Bool
        /// The report's first line, trimmed, or nil.
        var status: String?
        var name: String?
    }

    enum Outcome: Equatable, Error {
        case loaded(plans: [Plan], waves: [[String]])
        /// The failure code `no-phase-dir`: the phase is not planned in that root.
        case noPhaseDir
        case unreadable(String)
    }

    private static let timeoutSeconds: TimeInterval = 20

    /// `root` is the worktree or the project folder: both scripts read `.planning/phases/<N>` under it.
    static func run(_ scripts: CadenceLocator.Scripts, root: String, phase: String) -> Outcome {
        let timeout = timeoutSeconds
        guard UATStatus.isValidPhase(phase) else { return .unreadable("Phase text is not a plain number.") }
        let replay = call(scripts, root: root, command: "replay-check", phase: phase, timeout: timeout)
        let plans: [Plan]
        switch replay {
        case .failure(let outcome): return outcome
        case .success(let text):
            switch parseReplay(text) {
            case .loaded(let found, _): plans = found
            case let other: return other
            }
        }
        switch call(scripts, root: root, command: "plan-overlap", phase: phase, timeout: timeout) {
        case .failure(let outcome): return outcome
        case .success(let text):
            switch parseWaves(text) {
            case .success(let waves): return .loaded(plans: plans, waves: waves)
            case .failure(let outcome): return outcome
            }
        }
    }

    /// stdout is judged before the exit code: an `ok:false` answer exits non-zero.
    private static func call(_ scripts: CadenceLocator.Scripts, root: String, command: String, phase: String,
                             timeout: TimeInterval) -> Result<String, Outcome> {
        let result = ProcessRunner.run(
            scripts.node, [scripts.planning, command, "--phase", phase],
            environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()],
            workingFolder: root, timeout: timeout)
        if let startError = result.startError { return .failure(.unreadable("Cannot run node: \(startError).")) }
        if result.timedOut { return .failure(.unreadable("\(command) timed out after \(Int(timeout)) seconds.")) }
        if result.status != 0, !result.stdout.contains("\"ok\"") {
            return .failure(.unreadable("\(command) failed (exit \(result.status)): \(result.stderr.prefix(200))"))
        }
        return .success(result.stdout)
    }

    private static func object(_ text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The `ok:false` answer as an outcome, or nil when `root` says ok.
    private static func failure(_ root: [String: Any], _ command: String) -> Outcome? {
        guard root["ok"] as? Bool == true else {
            if root["reason"] as? String == "no-phase-dir" { return .noPhaseDir }
            return .unreadable("\(command) failed: \(root["reason"] as? String ?? "unknown reason").")
        }
        return nil
    }

    /// Plans only: the waves come from the second command, so a loaded result here has none.
    static func parseReplay(_ text: String) -> Outcome {
        guard let root = object(text) else { return .unreadable("replay-check printed no JSON.") }
        if let failed = failure(root, "replay-check") { return failed }
        guard let reports = root["reports"] as? [[String: Any]] else { return .unreadable("replay-check has no reports.") }
        var plans: [Plan] = []
        for item in reports {
            guard let file = item["plan"] as? String, let k = item["k"] as? Int
            else { return .unreadable("replay-check has an unknown plan entry.") }
            plans.append(Plan(file: file, k: k, exists: item["exists"] as? Bool ?? false,
                              status: (item["status"] as? String)?.trimmingCharacters(in: .whitespaces),
                              name: item["name"] as? String))
        }
        return .loaded(plans: plans, waves: [])
    }

    static func parseWaves(_ text: String) -> Result<[[String]], Outcome> {
        guard let root = object(text) else { return .failure(.unreadable("plan-overlap printed no JSON.")) }
        if let failed = failure(root, "plan-overlap") { return .failure(failed) }
        guard let waves = root["waves"] as? [[String]] else { return .failure(.unreadable("plan-overlap has no waves.")) }
        return .success(waves)
    }
}
