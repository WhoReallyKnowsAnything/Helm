import Testing
@testable import Helm

@Suite struct RunRecordSuggestTests {
    private let fixture = """
    {"ok":true,"file":".planning/trace.jsonl","scope":"all","events_read":771,"suggestions":[
     {"kind":"suggest","subject":"cad-executor","evidence":"8 of 60 resolves","action":"roles.cad-executor.effort","direction":"raise","current":"high"},
     {"kind":"suggest","subject":"cad-executor","evidence":"35 checkpoints","action":"workflow.max_plan_tasks","direction":"lower","current":8,"proposed":6},
     {"kind":"info","subject":"cad-planner","evidence":"start rung held","action":null},
     {"kind":"info","subject":"workers","evidence":"544 min","action":null},
     {"kind":"other","subject":"x","evidence":"dropped"}]}
    """

    private func parsed(_ text: String) -> RunRecordSuggest? {
        if case .success(let r) = RunRecordSuggest.parse(text) { return r }
        return nil
    }

    @Test func tweaksAndReceiptsSplitInSeamOrderAndOtherKindsDrop() throws {
        let r = try #require(parsed(fixture))
        #expect(r.tweaks.map(\.action) == ["roles.cad-executor.effort", "workflow.max_plan_tasks"])
        #expect(r.receipts.map(\.subject) == ["cad-planner", "workers"])
        #expect(r.file == ".planning/trace.jsonl" && r.scope == "all" && r.eventsRead == 771)
    }

    @Test func numbersKeepTheirPlainLiteralAndMissingProposedIsNil() throws {
        let r = try #require(parsed(fixture))
        #expect(r.tweaks[1].current == "8" && r.tweaks[1].proposed == "6" && r.tweaks[1].isPriced)
        #expect(r.tweaks[0].proposed == nil && !r.tweaks[0].isPriced && r.tweaks[0].current == "high")
        #expect(r.receipts[0].action == nil)
    }

    @Test func anEmptyListTellsZeroEventsFromManyEvents() throws {
        let none = try #require(parsed(#"{"ok":true,"file":"f","scope":"1","events_read":0,"suggestions":[]}"#))
        let many = try #require(parsed(#"{"ok":true,"file":"f","scope":"all","events_read":765,"suggestions":[]}"#))
        #expect(none.eventsRead == 0 && none.tweaks.isEmpty && none.receipts.isEmpty)
        #expect(many.eventsRead == 765)
    }

    @Test func failuresGiveAReason() {
        for text in ["", "garbage", #"{"ok":false,"reason":"no trace"}"#, #"{"ok":true,"file":"f"}"#] {
            guard case .failure(let f) = RunRecordSuggest.parse(text) else { Issue.record("expected failure"); continue }
            #expect(!f.reason.isEmpty)
        }
    }
}
