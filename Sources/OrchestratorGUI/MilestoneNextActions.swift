import Foundation

/// One short plain next action per break code, from section 3 of cadence-core `workflows/audit.md`. Pure: no I/O.
enum MilestoneNextActions {
    static func lines(for code: String) -> [String] {
        switch code {
        case "no-phase":
            return ["Nothing is committed to deliver this requirement. Plan it into a phase with /cad-plan."]
        case "phase-missing":
            return ["The table points at a phase that is not in ROADMAP.md. Fix the phase number or add the phase."]
        case "no-plan":
            return ["The phase has no plan for this requirement. Run /cad-plan for that phase."]
        case "not-verified":
            return ["The work is planned but not yet Complete and checked. Finish and verify the phase with /cad-verify."]
        case "drift":
            return ["The row status and the phase box disagree. Re-run /cad-verify or explain the difference."]
        case "unpicked":
            return ["No phase picked this requirement up. Plan it into a phase, or move it out of Active into the deferred section."]
        case "uncovered":
            return ["An acceptance criterion reached no UAT item. Add the item with /cad-verify, or correct the criterion id in CONTEXT.md."]
        case "fieldless-checklist":
            return ["The UAT checklist has no trace fields. Repair each item with uat record --criterion, or re-run /cad-verify."]
        case "version_drift":
            return ["Open the next version in PROJECT.md Active, and in the ROADMAP title if it names one.",
                    "Or, if the cycle is finished, complete the close so no phase is left open.",
                    "Or roll the work forward, once every Traceability row for that phase is Deferred."]
        default:
            return ["Unknown break code \(code). Run /cad-audit to see what it means."]
        }
    }
}
