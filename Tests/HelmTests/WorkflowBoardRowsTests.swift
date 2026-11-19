import Testing
@testable import Helm

struct WorkflowBoardRowsTests {
    private func overlay(_ state: WorkflowOverlay.State, stage: WorkflowGates.Stage = .execute,
                         question: Bool = false, ready: Bool = false) -> WorkflowOverlay {
        WorkflowOverlay(stage: stage, state: state, label: WorkflowDispatch.label(stage: stage, phase: "3"),
                        questionWaiting: question, planReady: ready)
    }

    @Test func progressCountsDoneRowsOverTotal() {
        #expect(WorkflowBoardRows.progress(WorkflowBoardFixture.board) == "1 of 5 phases done")
    }

    @Test func progressFallsBackToRowCountWithoutStatus() {
        var board = WorkflowBoardFixture.board
        board.status = nil
        #expect(WorkflowBoardRows.progress(board) == "1 of 5 phases done")
    }

    @Test func progressNeverReadsMoreDoneThanTotal() {
        let rows = (1...6).map { WorkflowBoard.Row(n: "\($0)", name: "p", display: .stage(.done)) }
        var status = WorkflowBoardFixture.status
        status.total = 5
        #expect(WorkflowBoardRows.progress(WorkflowBoard(milestone: "m", rows: rows, status: status)) == "6 of 6 phases done")
    }

    private func hold(_ label: String, state: GateHold.State = .live) -> GateHold {
        GateHold(id: "h", label: label, hash: String(repeating: "a", count: 64), epoch: 1, state: state, command: "x")
    }

    @Test func holdMarksOnlyItsOwnPhaseRow() {
        let holds = WorkflowBoardFixture.holds
        #expect(WorkflowBoardRows.holds(holds, phase: "3").count == 1)
        for other in ["1", "2", "4", "5"] { #expect(WorkflowBoardRows.holds(holds, phase: other).isEmpty) }
    }

    @Test func holdLabelsMatchExactlyAndOnlyWhenLive() {
        #expect(WorkflowBoardRows.holds([hold("cad-execute-p1-1")], phase: "1").isEmpty)
        #expect(WorkflowBoardRows.holds([hold("cad-config")], phase: "1").isEmpty)
        let label = WorkflowDispatch.label(stage: .execute, phase: "1")
        #expect(WorkflowBoardRows.holds([hold(label, state: .decided)], phase: "1").isEmpty)
        #expect(WorkflowBoardRows.holds([hold(label, state: .ghost)], phase: "1").isEmpty)
        #expect(WorkflowBoardRows.holds([hold(label)], phase: "1").count == 1)
    }

    @Test func phaseChipsLandOnRowsAndTheRestInTheMenu() {
        let split = WorkflowBoardRows.splitChips(WorkflowBoardFixture.chips, rows: WorkflowBoardFixture.rows)
        #expect(split.onRows["2"]?.map(\.skill) == ["/cadence:cad-coverage", "/cadence:cad-minimalism-review"])
        #expect(split.onRows["3"]?.map(\.skill) == ["/cadence:cad-decision-review"])
        #expect(split.menu.map(\.skill) == ["/cadence:cad-suggest"])
    }

    @Test func aPhaseChipWithNoRowStaysInTheMenuAndNothingIsDropped() {
        let ghost = CadenceChip(skill: "/cadence:cad-coverage", phase: "9", argument: nil, rule: "r")
        let health = CadenceChip(skill: "/cadence:cad-health", phase: nil, argument: nil, rule: "r")
        let audit = CadenceChip(skill: "/cadence:cad-audit", phase: nil, argument: nil, rule: "r")
        let input = WorkflowBoardFixture.chips + [ghost, health, audit]
        let split = WorkflowBoardRows.splitChips(input, rows: WorkflowBoardFixture.rows)
        #expect(split.onRows["9"] == nil)
        #expect(split.menu.contains(ghost) && split.menu.contains(health) && split.menu.contains(audit))
        #expect(split.onRows.values.joined().count + split.menu.count == input.count)
    }

    @Test func markUsesTheOverlayTextAndTheStatedStatus() {
        let cases: [(WorkflowOverlay, WorkerStatus)] = [
            (overlay(.running), .running),
            (overlay(.running, stage: .context, question: true), .waiting),
            (overlay(.waitingForMerge, stage: .plan, ready: true), .waiting),
            (overlay(.waitingForMerge), .waiting),
            (overlay(.dead), .dead),
        ]
        for (item, status) in cases {
            let mark = WorkflowBoardRows.mark(item)
            #expect(mark.status == status)
            #expect(mark.text == item.text)
        }
    }
}
