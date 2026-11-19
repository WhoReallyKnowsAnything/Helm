import Foundation
@testable import Helm

/// A realistic board for the phase 2 redesign (D-14): 5 phases in 4 stages, a dead worker, a live hold and a blocked
/// override reason. Only constructs values.
enum WorkflowBoardFixture {
    static let blocked = "G1: phase 4 has no plan yet"

    static let rows = [
        WorkflowBoard.Row(n: "1", name: "Shell header", display: .stage(.done)),
        WorkflowBoard.Row(n: "2", name: "Workflow screen redesign", display: .stage(.verify)),
        WorkflowBoard.Row(n: "3", name: "Wire holds", display: .stage(.planned)),
        WorkflowBoard.Row(n: "4", name: "Live board data", display: .stage(.context)),
        WorkflowBoard.Row(n: "5", name: "Release check", display: .stage(.planned)),
    ]

    static let chips = [
        CadenceChip(skill: "/cadence:cad-coverage", phase: "2", argument: nil, rule: "board rule: phase 2 is in verify"),
        CadenceChip(skill: "/cadence:cad-minimalism-review", phase: "2", argument: nil,
                    rule: "board rule: phase 2 is in verify", innerRole: "cad-reviewer: sonnet / medium"),
        CadenceChip(skill: "/cadence:cad-decision-review", phase: "3", argument: ".planning/phases/3/CONTEXT.md",
                    rule: "board rule: phase 3 has decisions"),
        CadenceChip(skill: "/cadence:cad-suggest", phase: nil, argument: nil, rule: "suggest: 2 ideas"),
    ]

    static let status = CadenceStatus(
        current: "3", total: 5, phases: rows.map { CadenceStatus.Phase(n: $0.n, name: $0.name, status: "planned") })

    static let board = WorkflowBoard(milestone: "v8 Workflow screen", rows: rows, status: status, chips: chips)

    static let overlays: [String: WorkflowOverlay] = [
        "2": WorkflowOverlay(stage: .verify, state: .dead, label: WorkflowDispatch.label(stage: .verify, phase: "2")),
        "3": WorkflowOverlay(stage: .execute, state: .running, label: WorkflowDispatch.label(stage: .execute, phase: "3")),
        "4": WorkflowOverlay(stage: .context, state: .running, label: WorkflowDispatch.label(stage: .context, phase: "4"),
                             questionWaiting: true),
        "5": WorkflowOverlay(stage: .plan, state: .waitingForMerge, label: WorkflowDispatch.label(stage: .plan, phase: "5"),
                             planReady: true),
    ]

    static let holds = [
        GateHold(id: "hold-3", label: WorkflowDispatch.label(stage: .execute, phase: "3"), hash: String(repeating: "a", count: 64),
                 epoch: 1, state: .live, command: "git commit -m wire holds"),
    ]

    static let executePhases: Set<String> = ["3"]

    static let panel = WorkflowPanel(
        next: .init(stage: .plan, phase: "5", routing: StageRouting.Entry(model: nil, effort: nil)),
        button: .off(blocked), roles: [],
        override: .init(stage: .plan, phase: "5", routing: StageRouting.Entry(model: nil, effort: nil)),
        overrideReason: blocked)
}
