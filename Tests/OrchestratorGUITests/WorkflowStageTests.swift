import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct WorkflowStageTests {
    private func status(current: String? = "1", cycle: String? = nil, total: Int = 3) -> CadenceStatus {
        CadenceStatus(current: current, total: total, cycle: cycle,
                      phases: [.init(n: "1", name: "a", status: "planned"), .init(n: "2", name: "b", status: "unplanned")],
                      cursorNext: nil)
    }

    @Test func mappingTable() {
        typealias M = WorkflowStageMap
        #expect(M.display(status: "unplanned", hasContext: false, skipDiscuss: false) == .stage(.context))
        #expect(M.display(status: "unplanned", hasContext: true, skipDiscuss: false) == .stage(.planned))
        #expect(M.display(status: "unplanned", hasContext: false, skipDiscuss: true) == .stage(.planned))
        #expect(M.display(status: "planned", hasContext: false, skipDiscuss: false) == .stage(.planned))
        #expect(M.display(status: "executed", hasContext: false, skipDiscuss: false) == .stage(.verify))
        #expect(M.display(status: "complete", hasContext: false, skipDiscuss: false) == .stage(.done))
        #expect(M.display(status: "mystery", hasContext: true, skipDiscuss: true) == .unknown("mystery"))
    }

    @Test func milestoneNameReadFromRoadmapText() {
        let roadmap = "# Roadmap: demo\n\n## Overview\n\nMilestone v3: Cadence workflow in the app. More text.\n"
        #expect(WorkflowStageMap.milestoneName(roadmap: roadmap, status: status()) == "Milestone v3: Cadence workflow in the app")
    }

    @Test func aDotInsideAVersionNumberStaysInTheMilestoneName() {
        let full = "Milestone v5: Canopy-Foreman on Cadence 4.3. Cadence 4.2 moved a project's records."
        #expect(WorkflowStageMap.milestoneName(roadmap: "## Overview\n\n" + full + "\n", status: status()) == "Milestone v5: Canopy-Foreman on Cadence 4.3")
        let endsAtDot = "Milestone v5: Canopy-Foreman on Cadence 4.3."
        #expect(WorkflowStageMap.milestoneName(roadmap: endsAtDot + "\n", status: status()) == "Milestone v5: Canopy-Foreman on Cadence 4.3")
    }

    @Test func fallbackAndClosedMilestone() {
        #expect(WorkflowStageMap.milestoneName(roadmap: "# Roadmap\n\nno milestone line", status: status(current: "2")) == "Phase 2 of 3")
        #expect(WorkflowStageMap.milestoneName(roadmap: nil, status: status()) == "Phase 1 of 3")
        #expect(WorkflowStageMap.milestoneName(roadmap: "Milestone v3: X.", status: status(current: nil, cycle: "none")) == "no open milestone")
    }

    @Test func contextPathUsesPhaseTextAndRefusesOddText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".planning/phases/1.1"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent(".planning/phases/1.1/CONTEXT.md"), atomically: true, encoding: .utf8)
        #expect(WorkflowStageMap.hasContext(project: dir.path, phase: "1.1"))
        #expect(!WorkflowStageMap.hasContext(project: dir.path, phase: "1"))
        #expect(!WorkflowStageMap.hasContext(project: dir.path, phase: "../1.1"))
    }
}
