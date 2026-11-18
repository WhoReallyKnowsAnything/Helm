import Foundation

/// The stage a phase shows on the board (D-03). "Executing" is never produced here: the running overlay adds it later.
enum WorkflowStage: String, Equatable {
    case context, planned, executing, verify, done
}

enum WorkflowStageMap {
    enum Display: Equatable {
        case stage(WorkflowStage)
        /// A status text this app does not know: shown as it is, with no stage.
        case unknown(String)
    }

    static func display(status: String, hasContext: Bool, skipDiscuss: Bool) -> Display {
        switch status {
        case "unplanned": return .stage(hasContext || skipDiscuss ? .planned : .context)
        case "planned": return .stage(.planned)
        case "executed": return .stage(.verify)
        case "complete": return .stage(.done)
        default: return .unknown(status)
        }
    }

    /// `phases/<n>/CONTEXT.md` with the phase text exactly. The text comes from a child process, so only a plain
    /// number is allowed into a path.
    static func hasContext(project: String, phase: String) -> Bool {
        guard phase.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return false }
        return FileManager.default.fileExists(atPath: "\(project)/.planning/phases/\(phase)/CONTEXT.md")
    }

    /// `phases/<n>/` holds `PLAN.md` or `PLAN-<digits>.md`. Same plain-number guard on the phase text as `hasContext`.
    static func hasPlans(project: String, phase: String) -> Bool {
        guard phase.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "\(project)/.planning/phases/\(phase)")) ?? []
        return names.contains { $0.range(of: #"^PLAN(-[0-9]+)?\.md$"#, options: .regularExpression) != nil }
    }

    /// D-02: the first "Milestone vN: name" line of the ROADMAP.md text, cut at its first full stop followed by white space or the line end (a dot in "4.3" stays); else
    /// "Phase n of total"; a closed milestone (`cycle: none`) reads "no open milestone".
    static func milestoneName(roadmap: String?, status: CadenceStatus) -> String {
        if status.cycle == "none" { return "no open milestone" }
        if let roadmap {
            for line in roadmap.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let match = line.range(of: #"^Milestone v[^:\s]+: (?:[^.]|\.(?!\s|$))+"#, options: .regularExpression) else { continue }
                return String(line[match]).trimmingCharacters(in: .whitespaces)
            }
        }
        let position = status.current.flatMap { current in status.phases.firstIndex { $0.n == current } }
        return "Phase \(position.map { $0 + 1 } ?? status.total) of \(status.total)"
    }
}
