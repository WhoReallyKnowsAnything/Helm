import Foundation
import Testing
@testable import Helm

@Suite struct PlanReviewTextTests {
    private func plan(_ name: String, action: String = "Do it.\n  Twice.", verify: String = "swift test") -> PlanReviewPlan {
        let task = ParsedPlan.Task(name: "Task 1: x", files: ["a.swift", "b.swift"], action: action, verify: verify)
        return PlanReviewPlan(name: name, parsed: ParsedPlan(
            phase: "4", plan: "1", requirements: ["R1"], files: [], dependsOn: nil, heading: "# Plan " + name,
            mustBeTrue: ["It works"], tasks: [task], raw: "raw"))
    }

    private func data(root: PlanReviewData.Root = .project, review: Bool = false) -> PlanReviewData {
        PlanReviewData(
            root: root, waves: [[plan("PLAN-1.md"), plan("PLAN-3.md")], [plan("PLAN-2.md")]], reviewExists: review,
            reviewPath: ".planning/phases/4/REVIEW-plan.md", criteria: (1...7).map { "AC\($0): c" })
    }

    private func make(_ d: PlanReviewData, state: PlanReviewState = .readyForReview(reviewInFlight: true),
                      card: ContextCardState.State = .noCard, entries: [RequestStore.Entry] = []) -> PlanReviewText {
        PlanReviewText.make(phase: "4", data: d, state: state, cardState: card, entries: entries, answered: [])
    }

    private var entry: RequestStore.Entry {
        RequestStore.Entry(
            key: "k", nodeKey: "cad-plan-p4",
            request: PermissionRequest(requestId: "r", toolName: "AskUserQuestion", toolUseId: "t", input: Data("{}".utf8),
                                       displayName: nil, text: "AskUserQuestion {}", reason: nil),
            live: true)
    }

    @Test func wavesKeepOrderAndPlanCounts() {
        let t = make(data())
        #expect(t.waves.map(\.title) == ["Wave 1", "Wave 2"])
        #expect(t.waves.map { $0.plans.map(\.name) } == [["PLAN-1.md", "PLAN-3.md"], ["PLAN-2.md"]])
    }

    @Test func taskTextIsCarriedAsWritten() {
        let task = make(data()).waves[0].plans[0].tasks[0]
        #expect(task.action == "Do it.\n  Twice." && task.verify == "swift test")
        #expect(task.files == ["a.swift", "b.swift"])
    }

    @Test func criteriaAppear() {
        #expect(make(data()).criteria.count == 7)
        #expect(make(data()).criteria.first == "AC1: c")
    }

    @Test func reviewLineFollowsTheFile() {
        let absent = make(data())
        #expect(absent.reviewLine == "review in flight" && !absent.reviewIsPath)
        let present = make(data(review: true), state: .readyForReview(reviewInFlight: false))
        #expect(present.reviewLine == ".planning/phases/4/REVIEW-plan.md" && present.reviewIsPath)
    }

    @Test func worktreeRootIsMarkedNotMerged() {
        #expect(make(data(root: .worktree)).note == "not merged yet")
        #expect(make(data(root: .project)).note == nil)
    }

    @Test func plannedStateNamesNoButton() {
        let t = make(data(), state: .planned)
        #expect(t.header.contains("Planned") && !t.header.lowercased().contains("button"))
        #expect(t.reviewLine == nil)
    }

    @Test func emptyDataSaysNoPlanFiles() {
        #expect(make(PlanReviewData(), state: .noPlan).emptyLine == "No plan files yet")
    }

    @Test func cardsByState() {
        #expect(make(data(), card: .answerable, entries: [entry]).answerableCount == 1)
        let ended = make(data(), card: .workerEnded, entries: [entry])
        #expect(ended.heldCards.map(\.stateLine) == ["worker ended"] && ended.offersClear && ended.answerableCount == 0)
        #expect(ended.heldCards.allSatisfy { !$0.showsButtons })
        let none = make(data(), card: .noCard, entries: [entry])
        #expect(none.heldCards.isEmpty && none.answerableCount == 0)
    }

    @Test func linkPredicateRejectsAbsoluteAndDotDot() {
        #expect(PlanReviewText.canLink("Sources/a.swift"))
        #expect(!PlanReviewText.canLink("/etc/passwd"))
        #expect(!PlanReviewText.canLink("../x"))
        #expect(!PlanReviewText.canLink("a/../../x"))
    }
}
