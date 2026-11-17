import Foundation

/// Runs one read-only `planning.mjs trace <subcommand>` seam (D-01). Same environment, working folder and timeout as
/// `CadenceSuggest.run`. Never `route.mjs`, never `trace.jsonl`.
enum RunRecordSeam {
    private static let timeoutSeconds: TimeInterval = 20

    static func run<T>(
        _ subcommand: String, _ scripts: CadenceLocator.Scripts, project: String, phase: String?,
        parse: (String) -> Result<T, CadenceLocator.Failure>
    ) -> Result<T, CadenceLocator.Failure> {
        let args = [scripts.planning, "trace", subcommand] + (phase.map { ["--phase", $0] } ?? [])
        let result = ProcessRunner.run(
            scripts.node, args,
            environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()],
            workingFolder: project, timeout: timeoutSeconds)
        if let startError = result.startError { return .failure(.init(reason: "Cannot run node: \(startError).")) }
        if result.timedOut { return .failure(.init(reason: "Cadence trace \(subcommand) timed out after \(Int(timeoutSeconds)) seconds.")) }
        let parsed = parse(result.stdout)
        if case .success = parsed { return parsed }
        if result.status != 0, !result.stdout.contains("\"ok\"") {
            return .failure(.init(reason: "Cadence trace \(subcommand) failed (exit \(result.status)): \(result.stderr.prefix(200))"))
        }
        return parsed
    }

    /// The JSON object of `text` when `ok` is true, else one plain reason (`reason`, `detail`, `hint` joined).
    static func object(_ text: String, name: String) -> Result<[String: Any], CadenceLocator.Failure> {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.init(reason: "Cadence trace \(name) gave output that is not JSON."))
        }
        guard root["ok"] as? Bool == true else {
            let parts = ["reason", "detail", "hint"].compactMap { root[$0] as? String }
            return .failure(.init(reason: parts.isEmpty ? "Cadence trace \(name) reported a failure." : parts.joined(separator: " ")))
        }
        return .success(root)
    }

    /// A JSON value as plain text: a string stays, a number or boolean becomes its literal, a list joins with "; ",
    /// null or absent is nil. Nothing is converted or recomputed.
    static func text(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case let list as [Any]: return list.compactMap { text($0) }.joined(separator: "; ")
        default: return nil
        }
    }
}

/// `planning.mjs trace render [--phase N]`: per-role figures and one row per dispatch (D-01, D-04).
struct RunRecordRender: Equatable {
    struct Role: Equatable {
        var name: String
        var dispatches: String?
        var tokens: String?
        var turns: String?
        var unrecorded: String?
        var turnsUnrecorded: String?
        /// D-04: the sum of this role's `brackets[].ms`, and the count of rows summed. The only arithmetic.
        var wallMs: Int64
        var wallCount: Int
    }

    struct Dispatch: Equatable {
        var role: String
        var plan: String
        var event: String
        var ms: String?
        var tokens: String?
        var turns: String?
    }

    var file: String
    var capped: String?
    var rotated: String?
    var malformed: String?
    var warnings: String?
    var roles: [Role]
    var brackets: [Dispatch]

    func dispatches(of role: String) -> [Dispatch] { brackets.filter { $0.role == role } }

    static func run(_ scripts: CadenceLocator.Scripts, project: String, phase: String?) -> Result<RunRecordRender, CadenceLocator.Failure> {
        RunRecordSeam.run("render", scripts, project: project, phase: phase, parse: parse)
    }

    static func parse(_ text: String) -> Result<RunRecordRender, CadenceLocator.Failure> {
        switch RunRecordSeam.object(text, name: "render") {
        case .failure(let failure): return .failure(failure)
        case .success(let root):
            let rows = (root["brackets"] as? [[String: Any]] ?? []).map { row in
                Dispatch(role: RunRecordSeam.text(row["role"]) ?? "", plan: RunRecordSeam.text(row["plan"]) ?? "",
                         event: RunRecordSeam.text(row["event"]) ?? "", ms: RunRecordSeam.text(row["ms"]),
                         tokens: RunRecordSeam.text(row["tokens"]), turns: RunRecordSeam.text(row["turns"]))
            }
            let rawRoles = root["roles"] as? [String: [String: Any]] ?? [:]
            let roles = rawRoles.keys.sorted().map { name -> Role in
                let figures = rawRoles[name] ?? [:]
                let sums = rows.filter { $0.role == name }.compactMap { $0.ms.flatMap(Int64.init) }
                return Role(name: name, dispatches: RunRecordSeam.text(figures["dispatches"]),
                            tokens: RunRecordSeam.text(figures["tokens"]), turns: RunRecordSeam.text(figures["turns"]),
                            unrecorded: RunRecordSeam.text(figures["unrecorded"]),
                            turnsUnrecorded: RunRecordSeam.text(figures["turns_unrecorded"]),
                            wallMs: sums.reduce(0, +), wallCount: sums.count)
            }
            return .success(RunRecordRender(
                file: RunRecordSeam.text(root["file"]) ?? "", capped: RunRecordSeam.text(root["capped"]),
                rotated: RunRecordSeam.text(root["rotated"]), malformed: RunRecordSeam.text(root["malformed"]),
                warnings: RunRecordSeam.text(root["warnings"]), roles: roles, brackets: rows))
        }
    }
}
