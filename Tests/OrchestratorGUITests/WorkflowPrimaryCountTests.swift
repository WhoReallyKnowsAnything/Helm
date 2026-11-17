import Foundation
import Testing
@testable import OrchestratorGUI

/// AC5 of phase 6: Execute, Run record and Milestone each show exactly one primary-style button. The count is structural
/// (source text), like the Board check of phase 5: no pixel comparison.
@MainActor
struct WorkflowPrimaryCountTests {
    private static let pass = MilestoneAudit(counts: .init(total: 1, broken: 0, kinds: []), requirementBreaks: [],
                                             coverageBreaks: [], deferred: [], drift: nil)
    private static let fail = MilestoneAudit(counts: .init(total: 1, broken: 1, kinds: []), requirementBreaks: [],
                                             coverageBreaks: [], deferred: [], drift: nil)

    @Test func structuralEachTabSourceHoldsOneActionRowAndNoOtherPrimary() throws {
        for name in ["ExecuteScreenView", "RunRecordView", "MilestoneScreenView"] {
            let text = try String(contentsOfFile: "Sources/OrchestratorGUI/\(name).swift", encoding: .utf8)
            #expect(text.components(separatedBy: "KitStageActionRow(").count - 1 == 1, "\(name) must draw one KitStageActionRow")
            #expect(!text.contains("kitPrimary"), "\(name) has a kitPrimary button")
            #expect(!text.contains("kind: .primary"), "\(name) has a primary-kind button")
        }
    }

    @Test func milestonePrimaryIsCloseWhileOpenAndLandOnceClosed() {
        let open = MilestoneScreenView.primary(audit: Self.pass, controlsOff: nil, landOff: "x", closed: false)
        #expect(open.title == "Close")
        #expect(open.off == nil)
        let closed = MilestoneScreenView.primary(audit: Self.pass, controlsOff: "held", landOff: nil, closed: true)
        #expect(closed.title == "Land")
        #expect(closed.off == nil)
    }

    @Test func milestonePrimaryIsOffWithAReasonInEachOffState() {
        #expect(MilestoneScreenView.primary(audit: Self.pass, controlsOff: "held", landOff: nil, closed: false).off == "held")
        #expect(MilestoneScreenView.primary(audit: nil, controlsOff: nil, landOff: nil, closed: false).off?.isEmpty == false)
        #expect(MilestoneScreenView.primary(audit: Self.fail, controlsOff: nil, landOff: nil, closed: false).off?.isEmpty == false)
        #expect(MilestoneScreenView.primary(audit: Self.pass, controlsOff: nil, landOff: "no worker", closed: true).off == "no worker")
    }

    @Test func executePrimaryIsOffForANilPanelAndWhileLive() {
        #expect(ExecuteScreenView.primaryOff(panel: nil, phase: "6", live: false) != nil)
        #expect(ExecuteScreenView.primaryOff(panel: nil, phase: "6", live: true) == "a plan is still running")
    }
}
