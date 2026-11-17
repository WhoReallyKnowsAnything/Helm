import Foundation

/// The answer of `planning.mjs uat status`, the only `uat` subcommand the app runs (it is read-only).
/// The counts and the result are Cadence's own; the app never counts items itself.
struct UATStatus: Equatable {
    struct Counts: Equatable {
        var pass = 0, fail = 0, pending = 0, skipped = 0, blocked = 0
    }

    struct FirstPending: Equatable {
        var k: Int
        var name: String
        var expected: String
    }

    var status: String
    var counts: Counts
    /// "complete" or "partial".
    var result: String
    var firstPending: FirstPending?
    /// The `ci` object as compact JSON text, when Cadence reports one.
    var ci: String?

    enum Outcome: Equatable {
        case loaded(UATStatus)
        /// The failure code `no-uat`: the verify worker has not created UAT.md yet.
        case notStarted
        case unreadable(String)
    }

    private static let timeoutSeconds: TimeInterval = 20

    /// Only a plain number is allowed into a process argument or a path.
    static func isValidPhase(_ phase: String) -> Bool {
        phase.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// `folder` is the verify worktree or the project folder: `uat status` reads `.planning/phases/<N>/UAT.md` under it.
    static func run(_ scripts: CadenceLocator.Scripts, folder: String, phase: String,
                    timeout: TimeInterval = timeoutSeconds) -> Outcome {
        guard isValidPhase(phase) else { return .unreadable("Phase text is not a plain number.") }
        let result = ProcessRunner.run(
            scripts.node, [scripts.planning, "uat", "status", "--phase", phase],
            environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()],
            workingFolder: folder, timeout: timeout)
        if let startError = result.startError { return .unreadable("Cannot run node: \(startError).") }
        if result.timedOut { return .unreadable("UAT status timed out after \(Int(timeout)) seconds.") }
        // ok:false answers come with a non-zero exit, so parse before judging the exit code.
        let parsed = parse(result.stdout)
        if case .unreadable = parsed, result.status != 0, !result.stdout.contains("\"ok\"") {
            return .unreadable("UAT status failed (exit \(result.status)): \(result.stderr.prefix(200))")
        }
        if case .loaded = parsed, result.status != 0 { return .unreadable("UAT status failed (exit \(result.status)).") }
        return parsed
    }

    static func parse(_ text: String) -> Outcome {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreadable("UAT status printed no JSON.") }
        guard root["ok"] as? Bool == true else {
            if root["reason"] as? String == "no-uat" { return .notStarted }
            return .unreadable("UAT status failed: \(root["reason"] as? String ?? "unknown reason").")
        }
        guard let result = root["result"] as? String, result == "complete" || result == "partial" else {
            return .unreadable("UAT status has an unknown result.")
        }
        guard let raw = root["counts"] as? [String: Any] else { return .unreadable("UAT status has no counts.") }
        let counts = Counts(pass: raw["pass"] as? Int ?? 0, fail: raw["fail"] as? Int ?? 0, pending: raw["pending"] as? Int ?? 0,
                            skipped: raw["skipped"] as? Int ?? 0, blocked: raw["blocked"] as? Int ?? 0)
        var first: FirstPending?
        if let item = root["first_pending"] as? [String: Any], let k = item["k"] as? Int {
            first = FirstPending(k: k, name: item["name"] as? String ?? "", expected: item["expected"] as? String ?? "")
        }
        var ci: String?
        if let object = root["ci"], JSONSerialization.isValidJSONObject(object),
           let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            ci = String(decoding: bytes, as: UTF8.self)
        }
        return .loaded(UATStatus(status: root["status"] as? String ?? "", counts: counts, result: result, firstPending: first, ci: ci))
    }
}
