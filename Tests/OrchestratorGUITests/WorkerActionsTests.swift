import Testing
@testable import OrchestratorGUI

struct WorkerActionsTests {
    private func actions(_ status: String, _ event: String?) -> WorkerActions {
        WorkerActions(row: WorkerRow(agentId: "alpha", status: status, taskTitle: nil, lastEvent: event))
    }

    @Test func aRunningWorkerWithDoneHasMergeOn() {
        #expect(actions("running", "done").mergeEnabled)
    }

    @Test(arguments: [("running", Optional("blocked")), ("running", nil), ("running", "working"), ("stalled", "done"), ("dead", "done"), ("merged", "done")])
    func anyOtherWorkerHasMergeOffWithAReason(status: String, event: String?) {
        let result = actions(status, event)
        #expect(!result.mergeEnabled)
        #expect(result.mergeHelp.contains("not finished"))
    }

    @Test(arguments: ["running", "blocked", "stalled", "dead", "starting"])
    func teardownIsOnForEveryDrawnWorker(status: String) {
        #expect(actions(status, nil).teardownEnabled)
        #expect(actions(status, "done").teardownEnabled)
    }

    // MARK: Mark done

    @Test(arguments: [
        ("running", Optional("idle"), true), ("running", "commit", true), ("running", nil, true),
        ("running", "done", false), ("merged", "done", false), ("merged", nil, false), ("dead", "idle", false),
        ("dead", "done", false), ("stalled", "idle", false), ("blocked", "idle", false),
    ])
    func markDoneShowsOnlyForARunningWorkerThatIsNotDone(status: String, event: String?, shown: Bool) {
        #expect(actions(status, event).markDoneShown == shown)
    }

    @Test func markDoneShowsInEveryPullRequestState() {
        for state in [PullRequestStore.State.loading, .unselected, .failed("x"), .loaded(nil)] {
            #expect(with("idle", state).markDoneShown)
        }
    }

    private func run(_ status: Int32, _ output: String, failure: MergeReview.Failure? = nil) -> MergeReview.Run {
        MergeReview.Run(output: output, status: status, failure: failure)
    }

    @Test func aSuccessfulMarkDoneShowsNoLine() {
        #expect(WorkerActions.markDoneFailure(run(0, "")) == nil)
    }

    @Test func aFailedMarkDoneShowsTheExitAndTheFirstOutputLine() {
        let line = WorkerActions.markDoneFailure(run(1, "Error: --mark-done refused: bad label\nsecond line\n"))
        #expect(line == "Mark done failed (exit 1): Error: --mark-done refused: bad label")
    }

    @Test func theFailureLineDropsControlCharactersAndIsCapped() {
        let noisy = "\u{1B}[31mred\u{07}" + String(repeating: "x", count: 500)
        let line = WorkerActions.markDoneFailure(run(2, noisy)) ?? ""
        #expect(!line.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
        #expect(line.hasPrefix("Mark done failed (exit 2): [31mred"))
        #expect(line.count <= "Mark done failed (exit 2): ".count + 200)
    }

    @Test func aRunThatDidNotStartShowsItsReason() {
        let line = WorkerActions.markDoneFailure(run(-1, "", failure: .didNotStart("no worktree")))
        #expect(line == "Mark done failed (exit -1): no worktree")
    }

    // MARK: pull request input (D-05)

    private func pr(_ number: Int, _ state: String, draft: Bool = false) -> PullRequest {
        PullRequest(
            number: number, url: "https://github.com/o/r/pull/\(number)", state: state, isDraft: draft,
            reviewDecision: "", title: "Fix login", checks: ChecksSummary(passed: 2), files: [], changedFiles: 3)
    }

    private func with(_ event: String?, _ state: PullRequestStore.State) -> WorkerActions {
        WorkerActions(row: WorkerRow(agentId: "alpha", status: "running", taskTitle: nil, lastEvent: event), pullRequest: state)
    }

    @Test(arguments: ["done", "working"])
    func loadingGivesMergeOffAndNoMergeAnyway(event: String) {
        for state in [PullRequestStore.State.loading, .unselected] {
            let result = with(event, state)
            #expect(!result.mergeEnabled && !result.mergeAnywayEnabled)
            #expect(result.mergeHelp == "checking the pull request")
        }
    }

    @Test func failedGivesMergeOffWithTheLookupTextAndAnywayOnWhenFinished() {
        let finished = with("done", .failed("gh: not logged in\nsecond"))
        #expect(!finished.mergeEnabled)
        #expect(finished.mergeHelp == "pull request lookup failed: gh: not logged in, press Refresh")
        #expect(finished.mergeAnywayEnabled)
        #expect(finished.summary == "pull request lookup failed: gh: not logged in")
        let working = with("working", .failed("x"))
        #expect(!working.mergeEnabled && !working.mergeAnywayEnabled)
    }

    @Test func everyStateOtherThanFailedHasNoMergeAnyway() {
        for state in [PullRequestStore.State.unselected, .loading, .loaded(nil), .loaded(pr(1, "OPEN")), .loaded(pr(2, "MERGED"))] {
            #expect(!with("done", state).mergeAnywayEnabled)
        }
    }

    @Test func noPullRequestAndFinishedGivesLocalMerge() {
        let result = with("done", .loaded(nil))
        #expect(result.mergeEnabled && result.mergeKind == .local && result.mergeTitle == "Merge")
        #expect(result.summary == "no pull request" && result.detail == nil)
    }

    @Test func anOpenPullRequestAndFinishedGivesAskOrchestrator() {
        let result = with("done", .loaded(pr(12, "OPEN")))
        #expect(result.mergeEnabled)
        #expect(result.mergeKind == .askOrchestrator(number: 12))
        #expect(result.mergeTitle == "Ask orchestrator to merge PR #12")
        #expect(result.summary == "#12 Fix login (open)")
        #expect(result.detail == "checks: 2 passed, 3 changed files")
    }

    @Test func aDraftPullRequestAlsoAsksTheOrchestrator() {
        #expect(with("done", .loaded(pr(5, "OPEN", draft: true))).mergeKind == .askOrchestrator(number: 5))
    }

    @Test func anOpenPullRequestAndNotFinishedGivesMergeOff() {
        let result = with("working", .loaded(pr(12, "OPEN")))
        #expect(!result.mergeEnabled)
        #expect(result.mergeHelp.contains("not finished"))
    }

    @Test(arguments: ["MERGED", "CLOSED"])
    func aMergedOrClosedPullRequestAndFinishedGivesLocalMerge(state: String) {
        let result = with("done", .loaded(pr(9, state)))
        #expect(result.mergeEnabled && result.mergeKind == .local && result.mergeTitle == "Merge")
        #expect(result.summary.hasSuffix("(\(state.lowercased()))"))
    }

    @Test(arguments: [PullRequestStore.State.unselected, .loading, .failed("x"), .loaded(nil), .loaded(PullRequest(
        number: 1, url: "", state: "OPEN", isDraft: false, reviewDecision: "", title: "t",
        checks: ChecksSummary(), files: [], changedFiles: 1))])
    func teardownStaysOnInEveryPullRequestState(state: PullRequestStore.State) {
        #expect(with("working", state).teardownEnabled)
        #expect(with("done", state).teardownEnabled)
    }

    // MARK: G3 (UAT gate)

    private func gated(_ label: String, _ state: PullRequestStore.State, _ uat: UATGate.Verdict) -> WorkerActions {
        WorkerActions(row: WorkerRow(agentId: label, status: "running", taskTitle: nil, lastEvent: "done"), pullRequest: state, uat: uat)
    }

    @Test(arguments: [PullRequestStore.State.unselected, .loading, .failed("x"), .loaded(nil), .loaded(PullRequest(
        number: 1, url: "", state: "OPEN", isDraft: false, reviewDecision: "", title: "t",
        checks: ChecksSummary(), files: [], changedFiles: 1)), .loaded(PullRequest(
        number: 2, url: "", state: "MERGED", isDraft: false, reviewDecision: "", title: "t",
        checks: ChecksSummary(), files: [], changedFiles: 1))])
    func aCheckingOrBlockedUatTurnsEveryMergeRouteOffForTheVerifyLabel(state: PullRequestStore.State) {
        for uat in [UATGate.Verdict.checking, .blocked("UAT partial")] {
            let result = gated("cad-verify-p3", state, uat)
            #expect(!result.mergeEnabled && !result.mergeAnywayEnabled)
            #expect(result.mergeHelp.contains("UAT"))
        }
    }

    @Test func allowedAndConfirmSkippedChangeNothing() {
        for state in [PullRequestStore.State.loaded(nil), .failed("x")] {
            let plain = gated("cad-verify-p3", state, .notGated)
            #expect(gated("cad-verify-p3", state, .allowed) == plain)
            #expect(gated("cad-verify-p3", state, .confirmSkipped(2)) == plain)
        }
    }

    @Test func otherLabelsIgnoreAVerifyVerdict() {
        for label in ["cad-execute-p1", "cad-plan-p1", "cad-context-p1", "alpha"] {
            for uat in [UATGate.Verdict.checking, .blocked("UAT partial")] {
                #expect(gated(label, .loaded(nil), uat) == gated(label, .loaded(nil), .notGated))
            }
        }
    }

    // MARK: Clear

    @Test func clearShowsOnlyForAnEndedWorker() {
        let row = WorkerRow(agentId: "alpha", status: "running", taskTitle: nil, lastEvent: nil)
        #expect(WorkerActions(row: row, ended: true).clearShown)
        #expect(!WorkerActions(row: row, ended: false).clearShown)
        #expect(!WorkerActions(row: row).clearShown)
    }

    // MARK: G3 override

    @Test func theOverrideDisplayIsCarriedAndDefaultsToHidden() {
        let row = WorkerRow(agentId: "cad-verify-p3", status: "running", taskTitle: nil, lastEvent: "done")
        #expect(WorkerActions(row: row).overrideDisplay == .hidden)
        #expect(WorkerActions(row: row, uat: .blocked("x"), override: .on).overrideDisplay == .on)
        let dead = UATOverride.Display.off(UATOverride.deadText)
        #expect(WorkerActions(row: row, uat: .blocked("x"), override: dead).overrideDisplay == dead)
        #expect(!WorkerActions(row: row, uat: .blocked("x"), override: .on).mergeEnabled)
    }
}
