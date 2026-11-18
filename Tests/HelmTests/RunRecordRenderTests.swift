import Testing
@testable import Helm

@Suite struct RunRecordRenderTests {
    private let fixture = """
    {"ok":true,"file":".planning/trace.jsonl","corr":"1-ec9f64c","capped":false,"counts":{"routing":1},
     "roles":{"cad-reviewer":{"dispatches":2,"tokens":233803,"turns":196,"unrecorded":4,"turns_unrecorded":4},
              "cad-planner":{"dispatches":1,"tokens":590340,"turns":256},
              "cad-idle":{"dispatches":0}},
     "brackets":[
      {"role":"cad-planner","plan":"cad-planner","event":"return","ms":1000,"tokens":10,"turns":2},
      {"role":"cad-reviewer","plan":"cad-reviewer","event":"return","ms":276968,"tokens":null},
      {"role":"cad-reviewer","plan":"cad-reviewer","event":"return","ms":32,"tokens":5,"turns":1}]}
    """

    private func parsed(_ text: String) -> RunRecordRender? {
        if case .success(let r) = RunRecordRender.parse(text) { return r }
        return nil
    }

    @Test func roleFiguresAreRelayedAndSortedByName() throws {
        let r = try #require(parsed(fixture))
        #expect(r.roles.map(\.name) == ["cad-idle", "cad-planner", "cad-reviewer"])
        let reviewer = r.roles[2]
        #expect(reviewer.dispatches == "2" && reviewer.tokens == "233803" && reviewer.turns == "196")
        #expect(reviewer.unrecorded == "4" && reviewer.turnsUnrecorded == "4")
        #expect(r.file == ".planning/trace.jsonl" && r.capped == "false" && r.rotated == nil)
    }

    @Test func wallClockIsTheSumOfThatRolesRows() throws {
        let reviewer = try #require(parsed(fixture)).roles[2]
        #expect(reviewer.wallMs == 276968 + 32 && reviewer.wallCount == 2)
    }

    @Test func anOmittedFigureStaysAbsent() throws {
        let planner = try #require(parsed(fixture)).roles[1]
        #expect(planner.unrecorded == nil && planner.turnsUnrecorded == nil)
    }

    @Test func aRoleWithNoRowsSumsToZeroOverZero() throws {
        let idle = try #require(parsed(fixture)).roles[0]
        #expect(idle.wallMs == 0 && idle.wallCount == 0)
    }

    @Test func dispatchRowsKeepNullTokensAndMissingTurnsAbsent() throws {
        let rows = try #require(parsed(fixture)).dispatches(of: "cad-reviewer")
        #expect(rows.count == 2)
        #expect(rows[0].tokens == nil && rows[0].turns == nil && rows[0].ms == "276968")
        #expect(rows[1].tokens == "5" && rows[1].turns == "1" && rows[1].event == "return")
    }

    @Test func failuresGiveAReason() {
        for text in ["", "not json", #"{"ok":false,"reason":"no trace","hint":"run something"}"#] {
            guard case .failure(let f) = RunRecordRender.parse(text) else { Issue.record("expected failure"); continue }
            #expect(!f.reason.isEmpty)
        }
    }
}
