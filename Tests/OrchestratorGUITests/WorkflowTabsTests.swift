import Testing
@testable import OrchestratorGUI

@Suite struct WorkflowTabsTests {
    private let rows = [WorkflowBoard.Row(n: "1.1", name: "Hotfix", display: .stage(.planned)),
                        WorkflowBoard.Row(n: "3", name: "Build", display: .stage(.verify))]

    private func status(current: String?) -> CadenceStatus {
        CadenceStatus(current: current, total: 2, cycle: nil, phases: [], cursorNext: nil)
    }

    @Test func sevenTabsFiveFollowThePhaseAndTwoAreProjectTabs() {
        #expect(WorkflowTabs.phaseTabs.map(\.title) == ["Board", "Context", "Plan", "Execute", "Verify"])
        #expect(WorkflowTabs.projectTabs.map(\.title) == ["Run Record", "Milestone"])
        #expect(WorkflowTabs.all.count == 7)
    }

    @Test func theCursorPhaseIsTheDefaultAndNilFallsBackToTheFirstRow() {
        #expect(WorkflowTabs.defaultPhase(status: status(current: "3"), rows: rows) == "3")
        #expect(WorkflowTabs.defaultPhase(status: status(current: nil), rows: rows) == "1.1")
        #expect(WorkflowTabs.defaultPhase(status: nil, rows: rows) == "1.1")
        #expect(WorkflowTabs.defaultPhase(status: status(current: "1.1"), rows: rows) == "1.1")
    }

    @Test func anEmptyRowListGivesNoPickerAndAReason() {
        #expect(WorkflowTabs.defaultPhase(status: nil, rows: []) == nil)
        #expect(WorkflowTabs.noPickerReason(rows: []) != nil)
        #expect(WorkflowTabs.noPickerReason(rows: rows) == nil)
    }

    @Test func theHeaderChangesWithThePhaseAndWithTheTab() {
        let a = WorkflowTabs.header(phase: "3", rows: rows, tab: "plan")
        #expect(a == "Phase 3  Build  /  Plan")
        #expect(WorkflowTabs.header(phase: "1.1", rows: rows, tab: "plan") != a)
        #expect(WorkflowTabs.header(phase: "3", rows: rows, tab: "run") == "Phase 3  Build  /  Run Record")
    }
}
