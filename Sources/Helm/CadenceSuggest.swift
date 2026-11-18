import Foundation

/// The `suggest` entries of `planning.mjs trace suggest` (D-03, D-04). Read-only: this one subcommand, no trace write,
/// no router. Entries of kind `info` are receipts and do not count.
struct CadenceSuggest: Equatable {
    struct Entry: Equatable {
        var subject: String
        var evidence: String
    }

    private static let timeoutSeconds: TimeInterval = 20

    static func run(_ scripts: CadenceLocator.Scripts, project: String) -> Result<[Entry], CadenceLocator.Failure> {
        let result = ProcessRunner.run(
            scripts.node, [scripts.planning, "trace", "suggest"],
            environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()],
            workingFolder: project, timeout: timeoutSeconds)
        if let startError = result.startError { return .failure(.init(reason: "Cannot run node: \(startError).")) }
        if result.timedOut { return .failure(.init(reason: "Cadence suggest timed out after \(Int(timeoutSeconds)) seconds.")) }
        let parsed = parse(result.stdout)
        if case .success = parsed { return parsed }
        if result.status != 0, !result.stdout.contains("\"ok\"") {
            return .failure(.init(reason: "Cadence suggest failed (exit \(result.status)): \(result.stderr.prefix(200))"))
        }
        return parsed
    }

    static func parse(_ text: String) -> Result<[Entry], CadenceLocator.Failure> {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.init(reason: "Cadence suggest gave output that is not JSON."))
        }
        guard root["ok"] as? Bool == true else {
            let parts = ["reason", "detail", "hint"].compactMap { root[$0] as? String }
            return .failure(.init(reason: parts.isEmpty ? "Cadence suggest reported a failure." : parts.joined(separator: " ")))
        }
        guard let list = root["suggestions"] as? [[String: Any]] else {
            return .failure(.init(reason: "Cadence suggest has no suggestion list."))
        }
        return .success(list.compactMap { item in
            guard item["kind"] as? String == "suggest" else { return nil }
            return Entry(subject: item["subject"] as? String ?? "", evidence: item["evidence"] as? String ?? "")
        })
    }
}
