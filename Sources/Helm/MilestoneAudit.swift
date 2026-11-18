import Foundation

/// One `planning.mjs audit` run plus one `criteria-coverage` run, and the one verdict rule over both (cad-audit section 4).
/// Read-only: nothing here writes.
struct MilestoneAudit: Equatable {
    struct Break: Equatable {
        var id: String?
        var phase: Int?
        var code: String
        /// Only for `fieldless-checklist`.
        var file: String?
    }

    struct Drift: Equatable {
        var docVersion: String
        var publishedAs: String
        var cycleState: String
    }

    /// The audit's own counts, so the health cell reads the same run as G4 (Task 5).
    var counts: CadenceConfig.Audit
    var requirementBreaks: [Break]
    var coverageBreaks: [Break]
    var deferred: [String]
    var drift: Drift?

    /// FAIL when any requirement is broken, any coverage break exists, or `version_drift` is present.
    var isFail: Bool { failCount > 0 }

    /// Broken plus coverage breaks plus 1 for drift. `counts.uncovered` of the coverage run is not used.
    var failCount: Int { counts.broken + coverageBreaks.count + (drift == nil ? 0 : 1) }

    /// Every break shown on the screen: requirement breaks first, then coverage breaks.
    var breaks: [Break] { requirementBreaks + coverageBreaks }

    private static let timeoutSeconds: TimeInterval = 20

    static func run(_ scripts: CadenceLocator.Scripts, project: String) -> Result<MilestoneAudit, CadenceLocator.Failure> {
        let audit = node(scripts, "audit", project: project)
        if let problem = failure(audit, what: "audit") { return .failure(problem) }
        let coverage = node(scripts, "criteria-coverage", project: project)
        if let problem = failure(coverage, what: "criteria-coverage") { return .failure(problem) }
        return parse(audit: audit.stdout, coverage: coverage.stdout)
    }

    static func parse(audit: String, coverage: String) -> Result<MilestoneAudit, CadenceLocator.Failure> {
        let counts: CadenceConfig.Audit
        switch CadenceConfig.parseAuditCounts(audit) {
        case .failure(let problem): return .failure(problem)
        case .success(let parsed): counts = parsed
        }
        guard let auditRoot = object(audit) else { return .failure(.init(reason: "Cadence audit gave output that is not JSON.")) }
        guard let coverageRoot = object(coverage) else {
            return .failure(.init(reason: "Cadence criteria-coverage gave output that is not JSON."))
        }
        guard coverageRoot["ok"] as? Bool == true else {
            let parts = ["reason", "detail", "hint"].compactMap { coverageRoot[$0] as? String }
            return .failure(.init(reason: parts.isEmpty ? "Cadence criteria-coverage reported a failure." : parts.joined(separator: " ")))
        }
        let requirementBreaks = (auditRoot["requirements"] as? [[String: Any]] ?? []).compactMap { entry -> Break? in
            guard let code = entry["break"] as? String else { return nil }
            return Break(id: entry["id"] as? String, phase: entry["phase"] as? Int, code: code, file: nil)
        }
        let coverageBreaks = (coverageRoot["breaks"] as? [[String: Any]] ?? []).compactMap { entry -> Break? in
            guard let code = entry["break"] as? String else { return nil }
            return Break(id: entry["id"] as? String, phase: entry["phase"] as? Int, code: code, file: entry["file"] as? String)
        }
        // `deferred` rows are listed, never counted. Accept bare ids or objects that carry an id.
        let deferred = (auditRoot["deferred"] as? [Any] ?? []).compactMap { item -> String? in
            (item as? String) ?? (item as? [String: Any])?["id"] as? String
        }
        var drift: Drift?
        if let raw = auditRoot["version_drift"] as? [String: Any] {
            drift = Drift(docVersion: raw["doc_version"] as? String ?? "",
                          publishedAs: raw["published_as"] as? String ?? "",
                          cycleState: raw["cycle_state"] as? String ?? "")
        }
        return .success(MilestoneAudit(counts: counts, requirementBreaks: requirementBreaks, coverageBreaks: coverageBreaks,
                                       deferred: deferred, drift: drift))
    }

    private static func node(_ scripts: CadenceLocator.Scripts, _ command: String, project: String) -> ProcessResult {
        ProcessRunner.run(
            scripts.node, [scripts.planning, command],
            environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()],
            workingFolder: project, timeout: timeoutSeconds)
    }

    private static func object(_ text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// A non-zero exit that still printed `"ok"` is parsed, as the other Cadence runs do.
    private static func failure(_ result: ProcessResult, what: String) -> CadenceLocator.Failure? {
        if let startError = result.startError { return .init(reason: "Cannot run node: \(startError).") }
        if result.timedOut { return .init(reason: "Cadence \(what) timed out after \(Int(timeoutSeconds)) seconds.") }
        if result.status != 0, !result.stdout.contains("\"ok\"") {
            return .init(reason: "Cadence \(what) failed (exit \(result.status)): \(result.stderr.prefix(200))")
        }
        return nil
    }
}
