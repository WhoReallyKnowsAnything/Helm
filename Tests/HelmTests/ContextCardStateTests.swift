import Foundation
import Testing
@testable import Helm

@Suite struct ContextCardStateTests {
    private let label = "cad-context-p3"
    private let entry = RequestStore.Entry(
        key: "k", nodeKey: "cad-context-p3",
        request: PermissionRequest(requestId: "r", toolName: "AskUserQuestion", toolUseId: "t", input: Data("{}".utf8),
                                   displayName: nil, text: "AskUserQuestion {}", reason: nil),
        live: true)

    private func state(_ overlay: WorkflowOverlay.State?, live: Bool = true, label: String? = nil) -> ContextCardState.State {
        ContextCardState.state(label: label ?? self.label, overlay: overlay, live: live)
    }

    @Test func runningAndLiveIsAnswerable() {
        #expect(state(.running) == .answerable)
    }

    @Test func deadIsWorkerEndedWithClearAndNoButtons() throws {
        for live in [true, false] {
            let s = state(.dead, live: live)
            #expect(s == .workerEnded)
            #expect(ContextCardState.offersClear(s))
            let card = try #require(ContextCardState.card(for: entry, state: s))
            #expect(card.stateLine == "worker ended" && !card.showsButtons && !card.enabled)
        }
    }

    @Test func waitingForMergeHasNoControls() throws {
        let s = state(.waitingForMerge)
        #expect(s == .waitingForMerge && !ContextCardState.offersClear(s))
        let card = try #require(ContextCardState.card(for: entry, state: s))
        #expect(!card.showsButtons && !card.enabled)
    }

    @Test func runningButNotLiveIsStarting() throws {
        let s = state(.running, live: false)
        #expect(s == .starting && !ContextCardState.offersClear(s))
        let card = try #require(ContextCardState.card(for: entry, state: s))
        #expect(!card.showsButtons && !card.enabled && card.stateLine != "worker ended")
    }

    @Test func overlayNoneGivesNoCard() {
        #expect(state(nil) == .noCard)
        #expect(ContextCardState.card(for: entry, state: .noCard) == nil)
    }

    @Test func labelOutsideTheTableGivesNoCard() {
        #expect(state(.running, label: "cad-config") == .noCard)
        #expect(state(.running, label: "cad-execute-p3x") == .noCard)
        #expect(state(.running, label: "xcad-execute-p3") == .noCard)
        #expect(state(.running, label: "dashboard") == .noCard)
    }

    @Test func aPlanLabelFollowsTheSameRulesAndExecuteFollowsThem() {
        let plan = "cad-plan-p4"
        #expect(state(.running, label: plan) == .answerable)
        #expect(state(.running, live: false, label: plan) == .starting)
        #expect(state(.dead, label: plan) == .workerEnded)
        #expect(ContextCardState.offersClear(state(.dead, label: plan)))
        #expect(state(.waitingForMerge, label: plan) == .waitingForMerge)
        #expect(state(nil, label: plan) == .noCard)
        let execute = "cad-execute-p4"
        #expect(state(.running, label: execute) == .answerable)
        #expect(state(.dead, label: execute) == .workerEnded)
    }

    @Test func theTableHoldsExecuteAndKeepsEveryEarlierEntry() {
        #expect(ContextCardState.screenStages.isSuperset(of: [.context, .plan, .execute, .verify, .milestone]))
        #expect(ContextCardState.dispatchStage(ofLabel: "cad-verify-p3") == .verify)
        #expect(ContextCardState.dispatchStage(ofLabel: "cad-verify-p1-1") == .verify)
        #expect(ContextCardState.hasScreen(label: "cad-execute-p3"))
        #expect(ContextCardState.hasScreen(label: "cad-execute-p1-1"))
        #expect(state(.running, label: "cad-verify-p3") == .answerable)
    }

    @Test func aMilestoneLabelIsAnswerableWhenLiveAndEndedWhenDead() {
        let label = "cad-milestone-p3"
        #expect(state(.running, label: label) == .answerable)
        #expect(state(.running, live: false, label: label) == .starting)
        #expect(state(.dead, label: label) == .workerEnded)
    }

    private var askEntry: RequestStore.Entry {
        let input = #"{"questions":[{"question":"Which scope?","header":"Scope","options":[{"label":"A","description":"a"}]},"#
            + #"{"question":"Which order?","header":"Order","options":[{"label":"B","description":"b"}]}]}"#
        return RequestStore.Entry(
            key: "k", nodeKey: label,
            request: PermissionRequest(requestId: "r", toolName: "AskUserQuestion", toolUseId: "t", input: Data(input.utf8),
                                       displayName: nil, text: "AskUserQuestion " + input, reason: nil),
            live: true)
    }

    @Test func nonAnswerableCardsShowQuestionTextNotJSON() throws {
        for s in [ContextCardState.State.workerEnded, .waitingForMerge, .starting] {
            let command = try #require(ContextCardState.card(for: askEntry, state: s)).command
            #expect(command.contains("Scope") && command.contains("Which scope?"))
            #expect(command.contains("Order") && command.contains("Which order?"))
            #expect(!command.contains("{") && !command.contains("AskUserQuestion"))
        }
    }
}

@Suite struct ExecuteOpenRuleTests {
    @Test func plansOrAnyHeldExecuteWorkerOffersOpen() {
        #expect(ContextCardState.offersOpenExecute(hasPlans: true, executeState: nil))
        for state in [WorkflowOverlay.State.running, .waitingForMerge, .dead] {
            #expect(ContextCardState.offersOpenExecute(hasPlans: false, executeState: state))
        }
        #expect(!ContextCardState.offersOpenExecute(hasPlans: false, executeState: nil))
    }

    @Test func hasPlansMatchesOnlyPlanFileNames() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        let phase = "\(dir)/.planning/phases/3"
        try FileManager.default.createDirectory(atPath: phase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for name in ["CONTEXT.md", "PLAN-x.md", "PLANNING.md"] {
            FileManager.default.createFile(atPath: "\(phase)/\(name)", contents: Data())
            #expect(!WorkflowStageMap.hasPlans(project: dir, phase: "3"))
        }
        FileManager.default.createFile(atPath: "\(phase)/PLAN-2.md", contents: Data())
        #expect(WorkflowStageMap.hasPlans(project: dir, phase: "3"))
        #expect(!WorkflowStageMap.hasPlans(project: dir, phase: "../3"))
    }
}
