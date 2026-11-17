import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct MilestoneAuditTests {
    private let cleanCoverage = #"{"ok":true,"phases":[],"breaks":[],"counts":{"criteria":31,"covered":13,"uncovered":18,"untraced":0,"phases":5}}"#
    private let cleanAudit = #"{"ok":true,"requirements":[{"id":"A-01","phase":1,"status":"Complete","box":true}],"counts":{"total":1,"traced":1,"broken":0,"deferred":0}}"#

    private let brokenAudit = #"""
    {"ok":true,"requirements":[
    {"id":"EXEC-01","phase":1,"status":"Complete","box":true},
    {"id":"EDIT-01","phase":4,"status":"Pending","box":false,"break":"not-verified"},
    {"id":"WF-01","phase":5,"status":"Pending","box":false,"break":"not-verified"},
    {"id":"LAND-01","phase":3,"status":"Pending","box":false,"break":"not-verified"},
    {"id":"X-01","status":"Pending","box":false,"break":"unpicked"},
    {"id":"X-02","status":"Pending","box":false,"break":"unpicked"}],
    "counts":{"total":7,"traced":2,"broken":5,"deferred":0}}
    """#

    private func parse(_ audit: String, _ coverage: String) throws -> MilestoneAudit {
        try MilestoneAudit.parse(audit: audit, coverage: coverage).get()
    }

    @Test func realAuditWithBrokenRowsFails() throws {
        let result = try parse(brokenAudit, cleanCoverage)
        #expect(result.isFail)
        #expect(result.failCount == 5)
        #expect(result.requirementBreaks.count == 5)
        #expect(result.requirementBreaks.map(\.code).contains("unpicked"))
        #expect(result.requirementBreaks.first { $0.id == "X-01" }?.phase == nil)
        #expect(result.requirementBreaks.first { $0.id == "LAND-01" }?.phase == 3)
    }

    @Test func cleanAuditPasses() throws {
        let result = try parse(cleanAudit, cleanCoverage)
        #expect(!result.isFail)
        #expect(result.failCount == 0)
        #expect(result.breaks.isEmpty)
    }

    @Test func uncoveredCountAloneDoesNotFail() throws {
        // cleanCoverage carries counts.uncovered 18 and no breaks: still PASS.
        #expect(try !parse(cleanAudit, cleanCoverage).isFail)
    }

    @Test func oneCoverageBreakFails() throws {
        let coverage = #"{"ok":true,"breaks":[{"phase":2,"id":"AC3","break":"uncovered"}]}"#
        let result = try parse(cleanAudit, coverage)
        #expect(result.isFail)
        #expect(result.failCount == 1)
        #expect(result.coverageBreaks == [.init(id: "AC3", phase: 2, code: "uncovered", file: nil)])
    }

    @Test func fieldlessChecklistKeepsItsFile() throws {
        let coverage = #"{"ok":true,"breaks":[{"phase":2,"break":"fieldless-checklist","file":".planning/phases/2/UAT.md"}]}"#
        let result = try parse(cleanAudit, coverage)
        #expect(result.coverageBreaks.first?.file == ".planning/phases/2/UAT.md")
        #expect(result.coverageBreaks.first?.id == nil)
    }

    @Test func driftAloneFails() throws {
        let audit = #"{"ok":true,"requirements":[],"counts":{"total":0,"traced":0,"broken":0,"deferred":0},"version_drift":{"doc_version":"v3","published_as":"v3.0.0","cycle_state":"open"}}"#
        let result = try parse(audit, cleanCoverage)
        #expect(result.isFail)
        #expect(result.failCount == 1)
        #expect(result.drift == .init(docVersion: "v3", publishedAs: "v3.0.0", cycleState: "open"))
    }

    @Test func deferredIsListedAndNotCounted() throws {
        let audit = #"{"ok":true,"requirements":[],"deferred":["D-01",{"id":"D-02"}],"counts":{"total":2,"traced":0,"broken":0,"deferred":2}}"#
        let result = try parse(audit, cleanCoverage)
        #expect(result.deferred == ["D-01", "D-02"])
        #expect(result.failCount == 0)
        #expect(!result.isFail)
    }

    @Test func failedOrGarbageRunsGiveTheReason() {
        let failed = #"{"ok":false,"reason":"no roadmap","detail":"missing","hint":"run /cad-new-project"}"#
        #expect(MilestoneAudit.parse(audit: failed, coverage: cleanCoverage) == .failure(.init(reason: "no roadmap missing run /cad-new-project")))
        #expect(MilestoneAudit.parse(audit: cleanAudit, coverage: failed) == .failure(.init(reason: "no roadmap missing run /cad-new-project")))
        #expect(MilestoneAudit.parse(audit: "not json", coverage: cleanCoverage) == .failure(.init(reason: "Cadence audit gave output that is not JSON.")))
        #expect(MilestoneAudit.parse(audit: cleanAudit, coverage: "nope") == .failure(.init(reason: "Cadence criteria-coverage gave output that is not JSON.")))
    }

    @Test func countsEqualParseAuditCountsOfTheSameStdout() throws {
        let result = try parse(brokenAudit, cleanCoverage)
        #expect(result.counts == (try CadenceConfig.parseAuditCounts(brokenAudit).get()))
    }
}
