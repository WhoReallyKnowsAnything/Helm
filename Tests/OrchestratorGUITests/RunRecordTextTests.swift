import Testing
@testable import OrchestratorGUI

@Suite struct RunRecordTextTests {
    private func result(rotated: String? = nil, events: Int = 771, tweaks: [RunRecordSuggest.Entry] = [], scope: String? = "all") -> RunRecordResult {
        let rows = [
            RunRecordRender.Dispatch(role: "cad-executor", plan: "p1", event: "return", ms: "100", tokens: "5", turns: nil),
            RunRecordRender.Dispatch(role: "cad-executor", plan: "p2", event: "return", ms: "23", tokens: nil, turns: "2")]
        let role = RunRecordRender.Role(name: "cad-executor", dispatches: "2", tokens: "5", turns: "2", unrecorded: nil,
                                        turnsUnrecorded: nil, wallMs: 123, wallCount: 2)
        let info = RunRecordSuggest.Entry(subject: "cad-planner", evidence: "rung held")
        return RunRecordResult(
            render: RunRecordRender(file: ".planning/trace.jsonl", capped: "false", rotated: rotated, roles: [role], brackets: rows),
            suggest: RunRecordSuggest(file: ".planning/trace.jsonl", scope: scope, eventsRead: events, tweaks: tweaks, receipts: [info]))
    }

    private let priced = RunRecordSuggest.Entry(subject: "cad-executor", evidence: "35 checkpoints", action: "workflow.max_plan_tasks",
                                                current: "8", direction: "lower", proposed: "6")
    private let unpriced = RunRecordSuggest.Entry(subject: "cad-executor", evidence: "8 of 60", action: "roles.cad-executor.effort",
                                                  current: "high", direction: "raise")

    @Test func wholeRecordScopeLineHasFileAndScopeAndNoNote() {
        let line = RunRecordText.make(phase: nil, result: result()).scopeLine ?? ""
        #expect(line.contains(".planning/trace.jsonl") && line.contains("scope: all") && !line.contains("older cycle"))
        #expect(!line.contains("rotated"))
    }

    @Test func aPhasePickAddsTheNoteAndRotatedShowsOnlyWhenSet() {
        let line = RunRecordText.make(phase: "1", result: result(rotated: "true", scope: "1")).scopeLine ?? ""
        #expect(line.contains("older cycle") && line.contains("rotated: true") && line.contains("scope: 1"))
    }

    @Test func roleWallClockIsTheSumAndAbsentFiguresSayNotGiven() {
        let role = RunRecordText.make(phase: nil, result: result()).roles[0]
        #expect(role.wallClock == "wall clock 123 ms (sum of 2 dispatches)")
        #expect(role.figures.contains("unrecorded not given") && role.figures.contains("dispatches 2"))
        #expect(role.dispatchRows.count == 2 && role.dispatchRows[0].contains("turns not given"))
    }

    @Test func tweaksAreNumberedPricedOnesCarryAPairAndInfoStaysInReceipts() {
        let text = RunRecordText.make(phase: nil, result: result(tweaks: [unpriced, priced]))
        #expect(text.tweaks.map(\.number) == [1, 2])
        #expect(text.tweaks[0].proposed == "no target priced" && !text.tweaks[0].priced && text.tweaks[0].pair == nil)
        #expect(text.tweaks[1].priced && text.tweaks[1].pair?.action == "workflow.max_plan_tasks" && text.tweaks[1].pair?.proposed == "6")
        #expect(text.receipts == ["cad-planner: rung held"] && text.emptyLine == nil)
    }

    @Test func bothEmptyListLines() {
        #expect(RunRecordText.make(phase: nil, result: result(events: 0)).emptyLine == "no events in scope")
        #expect(RunRecordText.make(phase: nil, result: result(events: 765)).emptyLine == "765 events read, none cleared the floors")
    }

    @Test func aFailureGivesReasonsAndNoRows() {
        let text = RunRecordText.make(phase: nil, result: RunRecordResult(reasons: ["render broke"]))
        #expect(text.reasons == ["render broke"] && text.roles.isEmpty && text.tweaks.isEmpty && text.scopeLine == nil)
    }

    @Test func pickerIsWholeRecordThenEachBoardPhase() {
        let rows = [WorkflowBoard.Row(n: "1", name: "Foo", display: .stage(.verify))]
        let options = RunRecordText.options(rows: rows)
        #expect(options.map(\.label) == ["Whole record", "1  Foo"] && options.map(\.phase) == [nil, "1"])
    }
}
