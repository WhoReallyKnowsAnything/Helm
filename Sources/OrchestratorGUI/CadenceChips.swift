import Foundation

/// One suggested skill on the board, with the rule that raised it (D-04). Display data only: a press builds its line
/// from the chip table in `WorkflowDispatch`.
struct CadenceChip: Equatable {
    var skill: String
    var phase: String?
    var argument: String?
    var rule: String
    /// The Cadence role that runs inside the skill, for minimalism-review and decision-review only.
    var innerRole: String?

    var label: String { WorkflowDispatch.label(skill: skill, phase: phase) }
}

/// The chip rules as pure functions of the board state. No state is kept, so a chip stays while its rule holds.
enum CadenceChips {
    static func make(rows: [WorkflowBoard.Row], next: WorkflowGates.Next?, drift: Int, suggest: [CadenceSuggest.Entry],
                     decisions: [String: Int], reviewerModel: String?, reviewerEffort: String?) -> [CadenceChip] {
        let reviewer = "cad-reviewer: \(reviewerModel ?? "unknown") / \(reviewerEffort ?? "unknown")"
        var chips: [CadenceChip] = []
        for row in rows {
            switch row.display {
            case .stage(.verify):
                chips.append(CadenceChip(skill: "/cadence:cad-coverage", phase: row.n,
                                         rule: "board rule: phase \(row.n) is in verify"))
                chips.append(CadenceChip(skill: "/cadence:cad-minimalism-review", phase: row.n,
                                         rule: "board rule: phase \(row.n) is in verify", innerRole: reviewer))
            case .stage(.planned) where (decisions[row.n] ?? 0) >= 1:
                chips.append(CadenceChip(skill: "/cadence:cad-decision-review", phase: row.n,
                                         argument: ".planning/phases/\(row.n)/CONTEXT.md",
                                         rule: "board rule: phase \(row.n) is planned with \(decisions[row.n] ?? 0) durable decisions",
                                         innerRole: reviewer))
            default: break
            }
        }
        if !suggest.isEmpty {
            var seen = Set<String>()
            let texts = suggest.map { "\($0.subject): \($0.evidence)" }.filter { seen.insert($0).inserted }
            chips.append(CadenceChip(skill: "/cadence:cad-suggest", phase: nil, rule: texts.joined(separator: "; ")))
        }
        if drift > 0 {
            chips.append(CadenceChip(skill: "/cadence:cad-health", phase: nil, rule: "board rule: status drift is \(drift)"))
        }
        if next?.stage == .milestone {
            chips.append(CadenceChip(skill: "/cadence:cad-audit", phase: nil, rule: "board rule: the next stage is milestone"))
        }
        return chips
    }

    /// Durable decisions per planned-stage phase. An unreadable CONTEXT.md gives no entry. `hasContext` allows only a plain
    /// phase number into the path.
    static func decisionCounts(project: String, rows: [WorkflowBoard.Row]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows where row.display == .stage(.planned) && WorkflowStageMap.hasContext(project: project, phase: row.n) {
            if let text = try? String(contentsOfFile: "\(project)/.planning/phases/\(row.n)/CONTEXT.md", encoding: .utf8) {
                counts[row.n] = durableDecisionCount(in: text)
            }
        }
        return counts
    }

    /// Lines `- D-<digits> (` between the `## Durable decisions` heading and the next `## ` heading. Not `## Decisions`.
    static func durableDecisionCount(in context: String) -> Int {
        var inside = false
        var count = 0
        for line in context.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") { inside = line.trimmingCharacters(in: .whitespaces) == "## Durable decisions" }
            else if inside, line.range(of: #"^- D-[0-9]+ \("#, options: .regularExpression) != nil { count += 1 }
        }
        return count
    }
}
