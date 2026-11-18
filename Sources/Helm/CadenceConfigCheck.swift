import Foundation

/// The 7 Cadence keys the board checks against the app's recommended set (CONFIG-01, D-07). Read-only: one `config.mjs get`.
struct CadenceConfigCheck: Equatable {
    enum Value: Equatable {
        case bool(Bool)
        case string(String)

        var text: String {
            switch self {
            case .bool(let flag): return String(flag)
            case .string(let text): return text
            }
        }
    }

    struct Row: Equatable {
        var key: String
        /// Nil when `config.mjs` returned no value for the key.
        var current: Value?
        var recommended: Value
        var differs: Bool
    }

    var rows: [Row]
    var warnings: [String]
    var reviewerModel: String
    var reviewerEffort: String

    /// The recommended set in display order. Plan 2 uses it as the allowlist of the config line.
    static let recommended: [(key: String, value: Value)] = [
        ("workflow.plan_check", .bool(true)),
        ("workflow.verifier", .bool(true)),
        ("planning.code_map", .bool(true)),
        ("review.triggers.plan.gate", .string("advisory")),
        ("review.triggers.diff.gate", .string("off")),
        ("review.triggers.risk_surface.gate", .string("blocking")),
        ("review.triggers.phase_diff.gate", .string("off")),
    ]

    static func recommendedValue(for key: String) -> Value? {
        recommended.first { $0.key == key }?.value
    }

    private static let reviewerKeys = ["roles.cad-reviewer.model", "roles.cad-reviewer.effort"]
    private static let timeoutSeconds: TimeInterval = 20

    static func run(_ scripts: CadenceLocator.Scripts, project: String) -> Result<CadenceConfigCheck, CadenceLocator.Failure> {
        func get(_ keys: [String]) -> ProcessResult {
            ProcessRunner.run(
                scripts.node, [scripts.config, "get"] + keys,
                environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()],
                workingFolder: project, timeout: timeoutSeconds)
        }
        let ownKeys = recommended.map(\.key)
        let first = get(ownKeys + reviewerKeys)
        if let startError = first.startError { return .failure(.init(reason: "Cannot run node: \(startError).")) }
        if first.timedOut { return .failure(.init(reason: "Cadence config timed out after \(Int(timeoutSeconds)) seconds.")) }
        if first.status != 0, !first.stdout.contains("\"ok\"") {
            return .failure(.init(reason: "Cadence config failed (exit \(first.status)): \(first.stderr.prefix(200))"))
        }
        return parse(first.stdout, retry: { get(ownKeys).stdout })
    }

    /// A project with no `roles` block makes the 9-key call fail on a role key alone: `retry` asks for the 7 keys, and the reviewer shows "unknown".
    static func parse(_ text: String, retry: () -> String) -> Result<CadenceConfigCheck, CadenceLocator.Failure> {
        guard let root = object(text) else { return .failure(.init(reason: "Cadence config gave output that is not JSON.")) }
        if root["ok"] as? Bool == false, root["reason"] as? String == "unknown-key",
           let unknown = root["detail"] as? [String], !unknown.isEmpty, unknown.allSatisfy(reviewerKeys.contains) {
            return parse(retry(), retry: { "" })
        }
        guard root["ok"] as? Bool == true, let values = root["values"] as? [String: Any] else {
            let detail = (root["detail"] as? [String])?.joined(separator: ", ") ?? root["detail"] as? String
            let parts = [root["reason"] as? String, detail, root["hint"] as? String].compactMap { $0 }
            return .failure(.init(reason: parts.isEmpty ? "Cadence config reported a failure." : parts.joined(separator: " ")))
        }
        let rows = recommended.map { entry -> Row in
            let current = value(values[entry.key])
            return Row(key: entry.key, current: current, recommended: entry.value, differs: current != entry.value)
        }
        return .success(CadenceConfigCheck(
            rows: rows, warnings: root["warnings"] as? [String] ?? [],
            reviewerModel: values[reviewerKeys[0]] as? String ?? "unknown",
            reviewerEffort: values[reviewerKeys[1]] as? String ?? "unknown"))
    }

    /// A JSON number is an NSNumber, so test for a real boolean before anything else.
    private static func value(_ raw: Any?) -> Value? {
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        return (raw as? String).map(Value.string)
    }

    private static func object(_ text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
