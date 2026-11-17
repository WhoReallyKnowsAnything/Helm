import XCTest
@testable import OrchestratorGUI

final class WorkflowDispatchTests: XCTestCase {
    private let opus = StageRouting.Entry(model: "opus", effort: "high")
    private let none = StageRouting.Entry(model: nil, effort: nil)

    private func line(_ stage: WorkflowGates.Stage = .execute, _ phase: String = "1", _ entry: StageRouting.Entry? = nil,
                      reason: String? = nil) -> Result<String, WorkflowDispatch.Refusal> {
        WorkflowDispatch.line(stage: stage, phase: phase, routing: entry ?? none, reason: reason)
    }

    func testContextLine() throws {
        XCTAssertEqual(try line(.context, "1", opus).get(),
                       "Cadence stage: skill=/cadence:cad-context phase=1 model=opus effort=high")
    }

    func testLandLineHasNoReasonAndNoArg() throws {
        let entry = StageRouting.Entry(model: "sonnet", effort: "high")
        let text = try WorkflowDispatch.line(skill: "/cadence:cad-land", phase: "3", routing: entry).get()
        XCTAssertEqual(text, "Cadence stage: skill=/cadence:cad-land phase=3 model=sonnet effort=high")
        XCTAssertFalse(text.contains(" reason:") || text.contains("arg="))
        XCTAssertEqual(WorkflowDispatch.label(skill: "/cadence:cad-land", phase: "3"), "cad-land-p3")
    }

    func testUnsetRoutingIsNone() throws {
        XCTAssertEqual(try line().get(), "Cadence stage: skill=/cadence:cad-execute phase=1 model=none effort=none")
    }

    func testLabels() {
        XCTAssertEqual(WorkflowDispatch.label(stage: .execute, phase: "1.1"), "cad-execute-p1-1")
        XCTAssertEqual(WorkflowDispatch.label(stage: .execute, phase: "3"), "cad-execute-p3")
    }

    func testNoPhaseNoArgumentLine() throws {
        let sonnet = StageRouting.Entry(model: "sonnet", effort: nil)
        XCTAssertEqual(try WorkflowDispatch.line(skill: "/cadence:cad-audit", phase: nil, routing: sonnet).get(),
                       "Cadence stage: skill=/cadence:cad-audit model=sonnet effort=none")
        XCTAssertEqual(WorkflowDispatch.label(skill: "/cadence:cad-audit", phase: nil), "cad-audit")
        XCTAssertEqual(WorkflowDispatch.label(skill: "/cadence:cad-coverage", phase: "3"), "cad-coverage-p3")
    }

    func testArgumentSitsBetweenPhaseAndModelAndReasonComesLast() throws {
        let sonnet = StageRouting.Entry(model: "sonnet", effort: nil)
        let path = ".planning/phases/1.1/CONTEXT.md"
        let text = try WorkflowDispatch.line(skill: "/cadence:cad-decision-review", phase: "1.1", argument: path,
                                             routing: sonnet, reason: "why").get()
        XCTAssertEqual(text, "Cadence stage: skill=/cadence:cad-decision-review phase=1.1 arg=\(path) model=sonnet effort=none reason: why")
        XCTAssertEqual(WorkflowDispatch.label(skill: "/cadence:cad-decision-review", phase: "1.1"), "cad-decision-review-p1-1")
    }

    private func chip(_ skill: String, _ phase: String? = nil, _ arg: String? = nil) -> Result<String, WorkflowDispatch.Refusal> {
        WorkflowDispatch.chipLine(skill: skill, phase: phase, argument: arg, routing: .init(model: "sonnet", effort: nil))
    }

    func testConfigLineKeepsTableOrder() throws {
        XCTAssertEqual(try chip("/cadence:cad-config", nil, "planning.code_map=true workflow.plan_check=true").get(),
                       "Cadence stage: skill=/cadence:cad-config arg=workflow.plan_check=true planning.code_map=true model=sonnet effort=none")
        XCTAssertEqual(WorkflowDispatch.label(skill: "/cadence:cad-config", phase: nil), "cad-config")
    }

    private func pair(_ action: String, _ proposed: String) -> Result<String, WorkflowDispatch.Refusal> {
        WorkflowDispatch.suggestionConfigLine(action: action, proposed: proposed, routing: .init(model: "sonnet", effort: nil))
    }

    func testSuggestionPairBuildsTheConfigLineOutsideTheFixedSeven() throws {
        XCTAssertEqual(try pair("workflow.max_plan_tasks", "7").get(),
                       "Cadence stage: skill=/cadence:cad-config arg=workflow.max_plan_tasks=7 model=sonnet effort=none")
    }

    func testSuggestionPairRefusesBadKeysAndValues() {
        let bad = [("--global", "true"), ("workflow.max_plan_tasks", ""), ("workflow.max_plan_tasks", "7 8"),
                   ("workflow max", "7"), ("--workflow.x", "7"), ("", "7"), ("workflow.x", "--global"), ("workflow.x", "a\nb")]
        for (key, value) in bad {
            guard case .failure(.badChip) = pair(key, value) else { return XCTFail("accepted: \(key)=\(value)") }
        }
    }

    func testConfigRefusesAnythingOffTheTable() {
        let bad = ["--global", "workflow.plan_check=true --global", "workflow.foo=true", "workflow.verifier=false",
                   "workflow.verifier=maybe", "workflow.plan_check=true workflow.verifier=false", "",
                   "workflow.plan_check=true  planning.code_map=true"]
        for arg in bad {
            guard case .failure(.badChip) = chip("/cadence:cad-config", nil, arg) else { return XCTFail("accepted: \(arg)") }
        }
        guard case .failure = chip("/cadence:cad-config") else { return XCTFail("no argument accepted") }
    }

    func testDecisionReviewArgumentIsFixedList() throws {
        XCTAssertNotNil(try? chip("/cadence:cad-decision-review", "2", ".planning/PROJECT.md").get())
        XCTAssertNotNil(try? chip("/cadence:cad-decision-review", "2", ".planning/phases/2/CONTEXT.md").get())
        for (phase, arg) in [("2", "../x.md"), ("1.1x", ".planning/phases/1.1x/CONTEXT.md"), ("2", ".planning/STATE.md"),
                             ("2", ".planning/phases/3/CONTEXT.md")] {
            guard case .failure = chip("/cadence:cad-decision-review", phase, arg) else { return XCTFail(arg) }
        }
    }

    func testChipShapesAndUnlistedSkills() throws {
        XCTAssertEqual(try chip("/cadence:cad-coverage", "3").get(),
                       "Cadence stage: skill=/cadence:cad-coverage phase=3 model=sonnet effort=none")
        XCTAssertEqual(chip("/cadence:cad-coverage", "1."), .failure(.badPhase("1.")))
        for skill in ["/cadence:cad-map", "/cadence:cad-capture", "/cadence:cad-context"] {
            guard case .failure(.badChip) = chip(skill, "1") else { return XCTFail(skill) }
        }
        guard case .failure(.badChip) = chip("/cadence:cad-audit", "1") else { return XCTFail("audit took a phase") }
    }

    func testBadArgumentIsRefusedNotCleaned() {
        for arg in ["a\nb", ""] {
            XCTAssertEqual(WorkflowDispatch.line(skill: "/cadence:cad-x", phase: nil, argument: arg, routing: none),
                           .failure(.badArgument(arg)))
        }
    }

    func testBadPhasesAreRefused() {
        for phase in ["1.1x", "1.", "", "1 2", "1\n", "x"] {
            XCTAssertEqual(line(.execute, phase), .failure(.badPhase(phase)), phase)
        }
    }

    func testReasonIsFlattenedToOneLine() throws {
        let text = try line(.plan, "1", reason: "a\n$(touch /tmp/ac5)").get()
        XCTAssertFalse(text.contains("\n"))
        XCTAssertTrue(text.hasSuffix(" reason: a $(touch /tmp/ac5)"))
    }

    func testReasonCannotChangeFixedFields() throws {
        let text = try line(.plan, "1", reason: "phase=2 skill=/cadence:cad-milestone").get()
        XCTAssertTrue(text.hasPrefix("Cadence stage: skill=/cadence:cad-plan phase=1 model=none effort=none reason: "))
        XCTAssertTrue(text.hasSuffix(" reason: phase=2 skill=/cadence:cad-milestone"))
    }

    func testLongReasonPassesWhole() throws {
        let reason = String(repeating: "r", count: 1500)
        XCTAssertTrue(try line(.plan, "1", reason: reason).get().hasSuffix(reason))
    }

    func testOverLimitLineIsRefusedNotCut() {
        let head = try! line(.plan, "1", reason: "x").get().unicodeScalars.count - 1
        XCTAssertNotNil(try? line(.plan, "1", reason: String(repeating: "r", count: 2000 - head)).get())
        guard case .failure(.tooLong(let count)) = line(.plan, "1", reason: String(repeating: "r", count: 2001 - head)) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(count, 2001)
    }

    func testEmptyReasonAndOpusMaxAreRefused() {
        XCTAssertEqual(line(.plan, "1", reason: " \n"), .failure(.emptyReason))
        guard case .failure(.badRouting) = line(.context, "1", .init(model: "opus", effort: "max")) else {
            return XCTFail("expected a refusal")
        }
    }
}
