import Foundation

/// The Cadence settings the board needs, read with one batched `config.mjs get`. The app never writes them (D-11).
struct CadenceConfig: Equatable {
    struct Role: Equatable {
        var model: String
        var effort: String
    }

    static let agents = ["cad-assumptions-analyzer", "cad-planner", "cad-plan-checker", "cad-executor", "cad-verifier"]

    var skipDiscuss: Bool
    var planCheck: Bool
    var roles: [String: Role]

    private static let timeoutSeconds: TimeInterval = 20
    private static var keys: [String] {
        ["workflow.skip_discuss", "workflow.plan_check"]
            + agents.flatMap { ["roles.\($0).model", "roles.\($0).effort"] }
    }

    private static func node(_ scripts: CadenceLocator.Scripts, _ script: String, _ arguments: [String], project: String) -> ProcessResult {
        ProcessRunner.run(
            scripts.node, [script] + arguments,
            environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()],
            workingFolder: project, timeout: timeoutSeconds)
    }

    /// One unknown key fails the whole call, so a failure here leaves the board with a reason and no next stage.
    static func run(_ scripts: CadenceLocator.Scripts, project: String) -> Result<CadenceConfig, CadenceLocator.Failure> {
        let result = node(scripts, scripts.config, ["get"] + keys, project: project)
        if let problem = failure(result, what: "config") { return .failure(problem) }
        return parse(result.stdout)
    }

    static func parse(_ text: String) -> Result<CadenceConfig, CadenceLocator.Failure> {
        guard let root = object(text) else { return .failure(.init(reason: "Cadence config gave output that is not JSON.")) }
        guard root["ok"] as? Bool == true, let values = root["values"] as? [String: Any] else {
            let parts = ["reason", "detail", "hint"].compactMap { root[$0] as? String }
            return .failure(.init(reason: parts.isEmpty ? "Cadence config reported a failure." : parts.joined(separator: " ")))
        }
        guard let skip = values["workflow.skip_discuss"] as? Bool, let check = values["workflow.plan_check"] as? Bool else {
            return .failure(.init(reason: "Cadence config has no workflow.skip_discuss or workflow.plan_check value."))
        }
        var roles: [String: Role] = [:]
        for agent in agents {
            guard let model = values["roles.\(agent).model"] as? String, let effort = values["roles.\(agent).effort"] as? String else {
                return .failure(.init(reason: "Cadence config has no model or effort for \(agent)."))
            }
            roles[agent] = Role(model: model, effort: effort)
        }
        return .success(CadenceConfig(skipDiscuss: skip, planCheck: check, roles: roles))
    }

    /// The milestone-wide counts of `planning.mjs audit`: `broken` feeds gate G4, all three feed the health cell.
    struct Audit: Equatable {
        var total: Int
        var broken: Int
        /// Distinct `break` values of the requirements, sorted. Empty when nothing is broken.
        var kinds: [String]
    }

    /// One audit run feeds both G4 and the health cell.
    static func runAudit(_ scripts: CadenceLocator.Scripts, project: String) -> Result<Audit, CadenceLocator.Failure> {
        let result = node(scripts, scripts.planning, ["audit"], project: project)
        if let problem = failure(result, what: "audit") { return .failure(problem) }
        return parseAuditCounts(result.stdout)
    }

    /// `counts.broken` only, for gate G4.
    static func parseAudit(_ text: String) -> Result<Int, CadenceLocator.Failure> {
        parseAuditCounts(text).map(\.broken)
    }

    static func parseAuditCounts(_ text: String) -> Result<Audit, CadenceLocator.Failure> {
        guard let root = object(text) else { return .failure(.init(reason: "Cadence audit gave output that is not JSON.")) }
        let counts = root["counts"] as? [String: Any]
        guard root["ok"] as? Bool == true, let broken = counts?["broken"] as? Int else {
            let parts = ["reason", "detail", "hint"].compactMap { root[$0] as? String }
            return .failure(.init(reason: parts.isEmpty ? "Cadence audit gave no broken count." : parts.joined(separator: " ")))
        }
        guard let total = counts?["total"] as? Int else { return .failure(.init(reason: "Cadence audit gave no total count.")) }
        let requirements = root["requirements"] as? [[String: Any]] ?? []
        let kinds = broken > 0 ? Array(Set(requirements.compactMap { $0["break"] as? String })).sorted() : []
        return .success(Audit(total: total, broken: broken, kinds: kinds))
    }

    private static func object(_ text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func failure(_ result: ProcessResult, what: String) -> CadenceLocator.Failure? {
        if let startError = result.startError { return .init(reason: "Cannot run node: \(startError).") }
        if result.timedOut { return .init(reason: "Cadence \(what) timed out after \(Int(timeoutSeconds)) seconds.") }
        if result.status != 0, !result.stdout.contains("\"ok\"") {
            return .init(reason: "Cadence \(what) failed (exit \(result.status)): \(result.stderr.prefix(200))")
        }
        return nil
    }
}
