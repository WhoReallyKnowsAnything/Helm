import Foundation

/// The answer of `planning.mjs status`. Phase numbers stay exact JSON text: a Double would print 3 as "3.0".
struct CadenceStatus: Equatable {
    struct Phase: Equatable {
        var n: String
        var name: String
        var status: String
    }

    var current: String?
    var total: Int
    /// Top-level only: "none" means a closed milestone, absent means open (`status.mjs:225`).
    var cycle: String?
    var phases: [Phase]
    /// Cadence's own hint, shown beside the app's derived stage and never trusted over it (D-05).
    var cursorNext: String?
    /// Entries in `drift` (0 when Cadence omits the key) and the plans listed across `outstanding` (D-01).
    var drift = 0
    var outstanding = 0

    private static let timeoutSeconds: TimeInterval = 20

    static func run(_ scripts: CadenceLocator.Scripts, project: String) -> Result<CadenceStatus, CadenceLocator.Failure> {
        let result = ProcessRunner.run(
            scripts.node, [scripts.planning, "status"],
            environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()],
            workingFolder: project, timeout: timeoutSeconds)
        if let startError = result.startError { return .failure(.init(reason: "Cannot run node: \(startError).")) }
        if result.timedOut { return .failure(.init(reason: "Cadence status timed out after \(Int(timeoutSeconds)) seconds.")) }
        // ok:false answers may come with a non-zero exit, so parse before judging the exit code.
        let parsed = parse(result.stdout)
        if case .success = parsed { return parsed }
        if result.status != 0, !result.stdout.contains("\"ok\"") {
            return .failure(.init(reason: "Cadence status failed (exit \(result.status)): \(result.stderr.prefix(200))"))
        }
        return parsed
    }

    static func parse(_ text: String) -> Result<CadenceStatus, CadenceLocator.Failure> {
        // Quote the number values of "n" and "current" before decoding, so their text survives.
        let quoted = text.replacingOccurrences(
            of: #""(n|current)"\s*:\s*(-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)"#,
            with: #""$1":"$2""#, options: .regularExpression)
        guard let data = quoted.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.init(reason: "Cadence status gave output that is not JSON."))
        }
        guard root["ok"] as? Bool == true else {
            let parts = ["reason", "detail", "hint"].compactMap { root[$0] as? String }
            return .failure(.init(reason: parts.isEmpty ? "Cadence status reported a failure." : parts.joined(separator: " ")))
        }
        guard let rawPhases = root["phases"] as? [[String: Any]] else {
            return .failure(.init(reason: "Cadence status has no phase list."))
        }
        let phases = rawPhases.compactMap { entry -> Phase? in
            guard let n = entry["n"] as? String else { return nil }
            return Phase(n: n, name: entry["name"] as? String ?? "", status: entry["status"] as? String ?? "")
        }
        var drift = 0
        if let raw = root["drift"] {
            guard let list = raw as? [Any] else { return .failure(.init(reason: "Cadence status has a drift value that is not a list.")) }
            drift = list.count
        }
        var outstanding = 0
        if let raw = root["outstanding"] {
            guard let list = raw as? [[String: Any]] else { return .failure(.init(reason: "Cadence status has an outstanding value that is not a list.")) }
            for entry in list {
                guard let plans = entry["plans"] as? [Any] else { return .failure(.init(reason: "Cadence status has an outstanding entry with no plans list.")) }
                outstanding += plans.count
            }
        }
        return .success(CadenceStatus(
            current: root["current"] as? String,
            total: root["total"] as? Int ?? phases.count,
            cycle: root["cycle"] as? String,
            phases: phases,
            cursorNext: (root["cursor"] as? [String: Any])?["next"] as? String,
            drift: drift, outstanding: outstanding))
    }
}
