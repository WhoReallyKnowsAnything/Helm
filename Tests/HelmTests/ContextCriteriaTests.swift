import Testing
@testable import Helm

@Suite struct ContextCriteriaTests {
    private let ac3 = "- [ ] AC3: One Notes press appends exactly 1 message to the plan worker's inbox: the fixed instruction first, then the user's text unchanged. After the worker finishes, the screen shows the edited plan from the worktree, and a new REVIEW-plan.md exists. (human-verify: needs a live worker)"

    private func context(_ acs: [String]) -> String {
        "## Decisions\n\n- D-01 (Approve): text\n\n## Acceptance criteria\n\n" + acs.joined(separator: "\n")
            + "\n\n## Flagged assumptions\n\n- [ ] AC9: not a criterion\n- D-02: nope\n"
    }

    @Test func phase4StyleYieldsAcsInOrderWithTheAC3Tail() {
        let acs = (1...7).map { $0 == 3 ? ac3 : "- [ ] AC\($0): text \($0)" }
        let parsed = ContextCriteria.parse(context(acs))
        #expect(parsed == acs)
        #expect(parsed[2].hasSuffix("(human-verify: needs a live worker)"))
    }

    @Test func phase3StyleYieldsEightAndCheckedBoxesCount() {
        let acs = (1...8).map { "- [\($0 == 2 ? "x" : " ")] AC\($0): text" }
        #expect(ContextCriteria.parse(context(acs)) == acs)
    }

    @Test func decisionsAndFlaggedAssumptionsYieldNothing() {
        #expect(ContextCriteria.parse("## Decisions\n\n- D-01: x\n\n## Flagged assumptions\n\n- [ ] AC1: y\n").isEmpty)
    }

    @Test func noSectionGivesEmptyList() {
        #expect(ContextCriteria.parse("# Title\n\ntext").isEmpty)
    }
}
