import Testing
@testable import Helm

@Suite struct PlanReviewParserTests {
    private let action = "A pure decision from facts about one resolved file (lowercased extension, is a directory). Data-driven: two constant sets, so a later type is one entry."
    private let verify = "`swift test --filter FileOpenPolicyTests` passes one case per row: `.sh` gives editor."

    private var plan: String {
        """
        ---
        phase: 3
        plan: 1
        requirements:
          - FILE-01
          - FILE-02
        files:
          - Sources/A.swift
        ---

        # Phase 3: Context screen - Plan 1: File-open helper

        ## Goal

        A goal.

        ## Must be true when done

        - First truth
        - Second truth

        ## Tasks

        ### Task 1: Open policy tables (pure)

        - **Files:** Sources/Helm/FileOpenPolicy.swift, Tests/HelmTests/FileOpenPolicyTests.swift
        - **Action:** \(action)
        - **Verify:** \(verify)

        ### Task 2: Second
        
        - **Files:** a.swift
        - **Action:** line one
        continues on a second line
        - **Verify:** ok
        """
    }

    @Test func parsesATaskExactlyAsWritten() {
        let parsed = PlanReviewParser.parse(plan)
        #expect(parsed.phase == "3" && parsed.plan == "1")
        #expect(parsed.tasks.count == 2)
        #expect(parsed.tasks[0].name == "Open policy tables (pure)")
        #expect(parsed.tasks[0].files == ["Sources/Helm/FileOpenPolicy.swift", "Tests/HelmTests/FileOpenPolicyTests.swift"])
        #expect(parsed.tasks[0].action == action)
        #expect(parsed.tasks[0].verify == verify)
        #expect(parsed.heading == "# Phase 3: Context screen - Plan 1: File-open helper")
    }

    @Test func aFieldThatContinuesOnASecondLineStaysWhole() {
        #expect(PlanReviewParser.parse(plan).tasks[1].action == "line one\ncontinues on a second line")
    }

    @Test func requirementsFromListLinesAndFromBrackets() {
        #expect(PlanReviewParser.parse(plan).requirements == ["FILE-01", "FILE-02"])
        let bracket = "---\nphase: 1\nrequirements: [SESS-01, MSG-01]\nfiles: [a, b]\n---\n# T\n"
        let parsed = PlanReviewParser.parse(bracket)
        #expect(parsed.requirements == ["SESS-01", "MSG-01"])
        #expect(parsed.files == ["a", "b"])
    }

    @Test func mustBeTrueBulletsComeBackInOrder() {
        #expect(PlanReviewParser.parse(plan).mustBeTrue == ["First truth", "Second truth"])
    }

    @Test func noTaskHeadingsGivesEmptyTasksAndRawText() {
        let text = "just some text\nwith no tasks"
        let parsed = PlanReviewParser.parse(text)
        #expect(parsed.tasks.isEmpty)
        #expect(parsed.raw == text)
    }

    @Test func dependsOnIsReturnedOnlyWhenPresent() {
        #expect(PlanReviewParser.parse(plan).dependsOn == nil)
        let withDeps = "---\nphase: 4\nplan: 2\ndepends_on:\n  - PLAN-1\n---\n"
        #expect(PlanReviewParser.parse(withDeps).dependsOn == ["PLAN-1"])
        #expect(PlanReviewParser.parse("---\ndepends_on: [PLAN-1, PLAN-2]\n---\n").dependsOn == ["PLAN-1", "PLAN-2"])
    }
}
