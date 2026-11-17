import XCTest
@testable import OrchestratorGUI

final class StageRoutingTests: XCTestCase {
    private func routing() -> StageRouting {
        StageRouting(defaults: UserDefaults(suiteName: "StageRoutingTests.\(UUID().uuidString)")!)
    }

    func testDefaultsPerStage() {
        let r = routing()
        XCTAssertEqual(r.entry(for: .context), .init(model: "opus", effort: "high"))
        XCTAssertEqual(r.entry(for: .milestone), .init(model: "opus", effort: "high"))
        for stage in [WorkflowGates.Stage.plan, .execute, .verify] {
            XCTAssertEqual(r.entry(for: stage), .init(model: nil, effort: nil))
        }
    }

    func testStoredChangeIsReadBack() {
        let r = routing()
        r.set(.init(model: "sonnet", effort: "low"), for: .execute)
        XCTAssertEqual(r.entry(for: .execute), .init(model: "sonnet", effort: "low"))
        r.set(.init(model: nil, effort: nil), for: .context)
        XCTAssertEqual(r.entry(for: .context), .init(model: nil, effort: nil))
    }

    func testOpusWithXhighOrMaxIsRefused() {
        XCTAssertNotNil(StageRouting.Entry(model: "opus", effort: "xhigh").refusal)
        XCTAssertNotNil(StageRouting.Entry(model: "opus", effort: "max").refusal)
        XCTAssertNil(StageRouting.Entry(model: "opus", effort: "high").refusal)
        XCTAssertNil(StageRouting.Entry(model: "sonnet", effort: "max").refusal)
    }

    func testUtilityDefaultIsSonnetWithNoEffort() {
        XCTAssertEqual(routing().utilityEntry(), .init(model: "sonnet", effort: nil))
    }

    func testUtilityChangeIsReadBackAndLeavesStagesAlone() {
        let r = routing()
        r.setUtility(.init(model: "haiku", effort: "low"))
        XCTAssertEqual(r.utilityEntry(), .init(model: "haiku", effort: "low"))
        XCTAssertEqual(r.entry(for: .context), .init(model: "opus", effort: "high"))
        XCTAssertEqual(r.entry(for: .execute), .init(model: nil, effort: nil))
    }

    func testUtilityOpusMaxIsRefused() {
        let r = routing()
        r.setUtility(.init(model: "opus", effort: "max"))
        XCTAssertNotNil(r.utilityEntry().refusal)
    }

    func testFreshSuiteReturnsDefaults() {
        XCTAssertEqual(routing().entry(for: .context), StageRouting.fallback(.context))
    }
}
