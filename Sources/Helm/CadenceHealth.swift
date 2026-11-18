import Foundation

/// The health strip of one project (HEALTH-01), one cell per source. Read-only: nothing here repairs anything.
/// A cell whose source fails holds its reason, so it never reads 0 and never blanks the other cells.
struct CadenceHealth: Equatable {
    typealias Cell = Result<Int, CadenceLocator.Failure>

    /// What the view draws for one cell. `warning` is true for an audit with broken requirements.
    struct Line: Equatable {
        var label: String
        var text: String
        var warning = false
    }

    var drift: Cell
    var audit: Result<CadenceConfig.Audit, CadenceLocator.Failure>
    var outstanding: Cell
    var debug: Cell
    var capture: Cell

    init(drift: Cell, audit: Result<CadenceConfig.Audit, CadenceLocator.Failure>, outstanding: Cell, debug: Cell = .success(0), capture: Cell = .success(0)) {
        self.drift = drift
        self.audit = audit
        self.outstanding = outstanding
        self.debug = debug
        self.capture = capture
    }

    /// Drift and outstanding come from the status read; a status that parsed always has both.
    init(status: CadenceStatus, audit: Result<CadenceConfig.Audit, CadenceLocator.Failure>, debug: Cell = .success(0), capture: Cell = .success(0)) {
        self.init(drift: .success(status.drift), audit: audit, outstanding: .success(status.outstanding), debug: debug, capture: capture)
    }

    /// `bullets` of the `Todos` section of `planning.mjs capture-sections` (D-01); `capture-check` is not used.
    static func openCaptureTodos(_ scripts: CadenceLocator.Scripts, project: String) -> Cell {
        let result = ProcessRunner.run(
            scripts.node, [scripts.planning, "capture-sections"],
            environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()],
            workingFolder: project, timeout: 20)
        if let startError = result.startError { return .failure(.init(reason: "Cannot run node: \(startError).")) }
        if result.timedOut { return .failure(.init(reason: "Cadence capture-sections timed out after 20 seconds.")) }
        if result.status != 0, !result.stdout.contains("\"ok\"") {
            return .failure(.init(reason: "Cadence capture-sections failed (exit \(result.status)): \(result.stderr.prefix(200))"))
        }
        return parseCaptureTodos(result.stdout)
    }

    static func parseCaptureTodos(_ text: String) -> Cell {
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.init(reason: "Cadence capture-sections gave output that is not JSON."))
        }
        guard root["ok"] as? Bool == true else {
            let parts = ["reason", "detail", "hint"].compactMap { root[$0] as? String }
            return .failure(.init(reason: parts.isEmpty ? "Cadence capture-sections reported a failure." : parts.joined(separator: " ")))
        }
        guard let sections = root["sections"] as? [[String: Any]] else {
            return .failure(.init(reason: "Cadence capture-sections has no section list."))
        }
        return .success(sections.first { $0["heading"] as? String == "Todos" }?["bullets"] as? Int ?? 0)
    }

    /// In the HEALTH-01 order.
    var lines: [Line] {
        [Line(label: "drift", text: Self.text(drift)),
         auditLine,
         Line(label: "outstanding plans", text: Self.text(outstanding)),
         Line(label: "open debug files", text: Self.text(debug)),
         Line(label: "open capture todos", text: Self.text(capture))]
    }

    /// Cadence's own rule (`debug.md`, the `list` route): a `*.md` file directly under `.planning/debug/` is open
    /// unless its first `Status:` line has the value `resolved`; no `Status:` line means open. A file that cannot
    /// be read fails the cell rather than lowering the count.
    static func openDebugFiles(project: String) -> Cell {
        let folder = project + "/.planning/debug"
        guard FileManager.default.fileExists(atPath: folder) else { return .success(0) }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: folder) } catch {
            return .failure(.init(reason: "Cannot list .planning/debug: \(error.localizedDescription)"))
        }
        var open = 0
        for name in names where name.hasSuffix(".md") {
            let text: String
            do { text = try String(contentsOfFile: folder + "/" + name, encoding: .utf8) } catch {
                return .failure(.init(reason: "Cannot read .planning/debug/\(name): \(error.localizedDescription)"))
            }
            let status = text.split(separator: "\n", omittingEmptySubsequences: false).first { $0.hasPrefix("Status:") }
            if status.map({ $0.dropFirst("Status:".count).trimmingCharacters(in: .whitespaces) != "resolved" }) ?? true { open += 1 }
        }
        return .success(open)
    }

    /// `broken/total` with the kinds beside it, for example `12/12 no-plan, not-verified`. No suppression (D-02).
    private var auditLine: Line {
        switch audit {
        case .failure(let problem):
            return Line(label: "audit", text: problem.reason)
        case .success(let counts):
            let kinds = counts.kinds.isEmpty ? "" : " " + counts.kinds.joined(separator: ", ")
            return Line(label: "audit", text: "\(counts.broken)/\(counts.total)\(kinds)", warning: counts.broken > 0)
        }
    }

    private static func text(_ cell: Cell) -> String {
        switch cell {
        case .success(let value): return String(value)
        case .failure(let problem): return problem.reason
        }
    }
}
