import Testing
@testable import OrchestratorGUI

@Suite struct MilestoneNextActionsTests {
    private let codes = ["no-phase", "phase-missing", "no-plan", "not-verified", "drift", "unpicked",
                         "uncovered", "fieldless-checklist", "version_drift"]

    @Test func everyCodeHasDistinctText() {
        let texts = codes.map { MilestoneNextActions.lines(for: $0).joined(separator: "\n") }
        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(Set(texts).count == codes.count)
    }

    @Test func versionDriftHasThreeLines() {
        #expect(MilestoneNextActions.lines(for: "version_drift").count == 3)
    }

    @Test func unknownCodeFallsBackAndNamesTheCode() {
        let lines = MilestoneNextActions.lines(for: "weird-code")
        #expect(lines.count == 1)
        #expect(lines[0].contains("weird-code"))
        #expect(lines[0].contains("/cad-audit"))
    }
}
