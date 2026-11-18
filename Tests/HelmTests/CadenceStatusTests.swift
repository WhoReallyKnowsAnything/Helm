import Foundation
import Testing
@testable import Helm

@Suite struct CadenceStatusTests {
    private func ok(_ result: Result<CadenceStatus, CadenceLocator.Failure>) throws -> CadenceStatus {
        try result.get()
    }

    @Test func wholeNumberKeepsItsText() throws {
        let json = #"{"ok":true,"current":3,"total":3,"phases":[{"n":1,"name":"A","status":"complete"},{"n":3,"name":"C","status":"unplanned"}],"cursor":{"phase":3,"next":"/cad-context 3"}}"#
        let s = try ok(CadenceStatus.parse(json))
        #expect(s.current == "3")
        #expect(s.phases.map(\.n) == ["1", "3"])
        #expect(s.cursorNext == "/cad-context 3")
        #expect(s.cycle == nil)
    }

    @Test func duplicateDecimalTextArrivesTwice() throws {
        let json = #"{"ok":true,"current":null,"total":2,"cycle":"none","phases":[{"n":1.1,"name":"x","status":"complete"},{"n":1.1,"name":"y","status":"complete"}]}"#
        let s = try ok(CadenceStatus.parse(json))
        #expect(s.phases.map(\.n) == ["1.1", "1.1"])
        #expect(s.current == nil)
        #expect(s.cycle == "none")
    }

    @Test func okFalseSurfacesReasonDetailAndHint() {
        let json = #"{"ok":false,"reason":"no-roadmap","detail":"ROADMAP.md is missing","hint":"run cad-new-project"}"#
        guard case .failure(let f) = CadenceStatus.parse(json) else { Issue.record("expected failure"); return }
        #expect(f.reason.contains("no-roadmap"))
        #expect(f.reason.contains("ROADMAP.md is missing"))
        #expect(f.reason.contains("run cad-new-project"))
    }

    private func head(_ extra: String) -> String {
        #"{"ok":true,"current":1,"total":1,"phases":[{"n":1,"name":"A","status":"complete"}]"# + extra + "}"
    }

    @Test func missingDriftAndOutstandingGiveZero() throws {
        let s = try ok(CadenceStatus.parse(head("")))
        #expect(s.drift == 0)
        #expect(s.outstanding == 0)
    }

    @Test func driftCountsEntries() throws {
        let s = try ok(CadenceStatus.parse(head(#","drift":[{"kind":"a"},{"kind":"b"},{"kind":"c"}]"#)))
        #expect(s.drift == 3)
    }

    @Test func outstandingSumsPlans() throws {
        let json = head(#","outstanding":[{"phase":1,"plans":["PLAN-1.md","PLAN-2.md"]},{"phase":2,"plans":["PLAN-1.md"]}]"#)
        #expect(try ok(CadenceStatus.parse(json)).outstanding == 3)
        #expect(try ok(CadenceStatus.parse(head(#","outstanding":[]"#))).outstanding == 0)
    }

    @Test func wrongTypesGiveAReason() {
        for extra in [#","drift":"x""#, #","outstanding":"x""#, #","outstanding":[{"phase":1}]"#] {
            guard case .failure(let f) = CadenceStatus.parse(head(extra)) else { Issue.record("expected failure for \(extra)"); continue }
            #expect(!f.reason.isEmpty)
        }
    }

    @Test func garbageGivesAReason() {
        guard case .failure(let f) = CadenceStatus.parse("node: command exploded") else { Issue.record("expected failure"); return }
        #expect(!f.reason.isEmpty)
    }

    @Test func runReportsMissingNode() {
        let scripts = CadenceLocator.Scripts(node: "/nonexistent/node", planning: "/x/planning.mjs", config: "/x/config.mjs")
        guard case .failure(let f) = CadenceStatus.run(scripts, project: NSTemporaryDirectory()) else { Issue.record("expected failure"); return }
        #expect(f.reason.contains("node"))
    }
}
