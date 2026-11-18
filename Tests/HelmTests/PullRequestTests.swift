import Foundation
import Testing
@testable import Helm

/// The real output of `gh pr list --head phase/4-approvals-alerts --state all --json <the D-15 fields>` in this repo
/// (gh 2.103.3, 2026-11-01): PR #4, merged, 49 changed files, an empty `statusCheckRollup`.
private let realOutput = #"""
[{"changedFiles":49,"files":[{"path":".planning/REQUIREMENTS.md","additions":8,"deletions":3,"changeType":"MODIFIED"},{"path":".planning/ROADMAP.md","additions":2,"deletions":2,"changeType":"MODIFIED"},{"path":".planning/STATE.md","additions":3,"deletions":3,"changeType":"MODIFIED"},{"path":".planning/phases/3/UAT.md","additions":5,"deletions":5,"changeType":"MODIFIED"},{"path":".planning/phases/4/ADJUDICATION-risk_surface-plan-1-r2.json","additions":35,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/ADJUDICATION-risk_surface-plan-1.json","additions":35,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/ADJUDICATION-risk_surface-plan-2.json","additions":20,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/FINDINGS.json","additions":9,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/PLAN-1.md","additions":121,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/PLAN-2.md","additions":106,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/REVIEW-plan.md","additions":22,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/REVIEW-risk_surface-plan-1-r2.md","additions":7,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/REVIEW-risk_surface-plan-1.md","additions":7,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/REVIEW-risk_surface-plan-2.md","additions":1,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/SUMMARY.md","additions":85,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/UAT.md","additions":108,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/reports/plan-1.1.md","additions":14,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/reports/plan-1.2.md","additions":19,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/reports/plan-1.md","additions":37,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/reports/plan-2.md","additions":28,"deletions":0,"changeType":"ADDED"},{"path":".planning/phases/4/verifier-findings.json","additions":35,"deletions":0,"changeType":"ADDED"},{"path":"Sources/Helm/AlertNotifier.swift","additions":76,"deletions":0,"changeType":"ADDED"},{"path":"Sources/Helm/AlertStore.swift","additions":150,"deletions":0,"changeType":"ADDED"},{"path":"Sources/Helm/AlertTracker.swift","additions":92,"deletions":0,"changeType":"ADDED"},{"path":"Sources/Helm/ContentView.swift","additions":69,"deletions":7,"changeType":"MODIFIED"},{"path":"Sources/Helm/GateHold.swift","additions":136,"deletions":0,"changeType":"ADDED"},{"path":"Sources/Helm/GateHoldReader.swift","additions":69,"deletions":0,"changeType":"ADDED"},{"path":"Sources/Helm/HoldDecider.swift","additions":52,"deletions":0,"changeType":"ADDED"},{"path":"Sources/Helm/HoldStore.swift","additions":205,"deletions":0,"changeType":"ADDED"},{"path":"Sources/Helm/OrchestratorGUIApp.swift","additions":54,"deletions":4,"changeType":"MODIFIED"},{"path":"Sources/Helm/ProjectWatcher.swift","additions":31,"deletions":11,"changeType":"MODIFIED"},{"path":"Sources/Helm/TreeLayout.swift","additions":8,"deletions":3,"changeType":"MODIFIED"},{"path":"Sources/Helm/WorkerDatabase.swift","additions":5,"deletions":2,"changeType":"MODIFIED"},{"path":"Sources/Helm/WorkerTree.swift","additions":31,"deletions":3,"changeType":"MODIFIED"},{"path":"Sources/Helm/WorkerTreeView.swift","additions":164,"deletions":2,"changeType":"MODIFIED"},{"path":"Tests/HelmTests/AlertNotifierTests.swift","additions":45,"deletions":0,"changeType":"ADDED"},{"path":"Tests/HelmTests/AlertStoreTests.swift","additions":199,"deletions":0,"changeType":"ADDED"},{"path":"Tests/HelmTests/AlertTrackerTests.swift","additions":129,"deletions":0,"changeType":"ADDED"},{"path":"Tests/HelmTests/FixtureHolds.swift","additions":60,"deletions":0,"changeType":"ADDED"},{"path":"Tests/HelmTests/GateHoldReaderTests.swift","additions":127,"deletions":0,"changeType":"ADDED"},{"path":"Tests/HelmTests/GateHoldTests.swift","additions":151,"deletions":0,"changeType":"ADDED"},{"path":"Tests/HelmTests/HoldDeciderTests.swift","additions":155,"deletions":0,"changeType":"ADDED"},{"path":"Tests/HelmTests/HoldStoreTests.swift","additions":439,"deletions":0,"changeType":"ADDED"},{"path":"Tests/HelmTests/NoApprovePathTests.swift","additions":90,"deletions":0,"changeType":"ADDED"},{"path":"Tests/HelmTests/NodeInfoTests.swift","additions":1,"deletions":1,"changeType":"MODIFIED"},{"path":"Tests/HelmTests/ProjectWatcherTests.swift","additions":71,"deletions":0,"changeType":"MODIFIED"},{"path":"Tests/HelmTests/TreeLayoutTests.swift","additions":29,"deletions":5,"changeType":"MODIFIED"},{"path":"Tests/HelmTests/WorkerDatabaseTests.swift","additions":21,"deletions":0,"changeType":"MODIFIED"},{"path":"Tests/HelmTests/WorkerTreeTests.swift","additions":106,"deletions":0,"changeType":"MODIFIED"}],"headRefOid":"39335d77b31587d5306ac110be147b815e976689","isDraft":false,"mergeStateStatus":"UNKNOWN","mergeable":"UNKNOWN","number":4,"reviewDecision":"","state":"MERGED","statusCheckRollup":[],"title":"Phase 4: Approvals and alerts","url":"https://github.com/WhoReallyKnowsAnything/orchestrator-gui/pull/4"}]
"""#

private func pullRequest(_ fields: String) throws -> PullRequest {
    try #require(try PullRequest.decode("[{\(fields)}]").first)
}

private func rollup(_ entries: String) throws -> ChecksSummary {
    try pullRequest(#""number":1,"statusCheckRollup":[\#(entries)]"#).checks
}

struct PullRequestTests {
    @Test func theRealMergedPullRequestDecodes() throws {
        let list = try PullRequest.decode(realOutput)
        #expect(list.count == 1)
        let pr = list[0]
        #expect(pr.number == 4)
        #expect(pr.state == "MERGED")
        #expect(pr.stateWords == "merged")
        #expect(pr.changedFiles == 49)
        #expect(pr.files.count == 49)
        #expect(pr.files[0] == PullRequestFile(path: ".planning/REQUIREMENTS.md", additions: 8, deletions: 3))
        #expect(!pr.filesCapped)
        #expect(pr.checks.text == "no checks")
        #expect(pr.title == "Phase 4: Approvals and alerts")
    }

    @Test func unknownFieldsAreIgnoredAndMissingOptionalFieldsAreNotAnError() throws {
        let pr = try pullRequest(#""number":7,"somethingNew":{"a":1},"state":"OPEN""#)
        #expect(pr.number == 7)
        #expect(pr.isOpen)
        #expect(pr.files.isEmpty)
        #expect(pr.changedFiles == 0)
        #expect(pr.checks.text == "no checks")
        #expect(pr.reviewDecision == "")
    }

    @Test func aMissingNumberIsAnError() {
        #expect(throws: (any Error).self) { try PullRequest.decode(#"[{"state":"OPEN"}]"#) }
        #expect(throws: (any Error).self) { try PullRequest.decode("") }
    }

    @Test func stateWordsAreLowercaseText() throws {
        #expect(try pullRequest(#""number":1,"state":"OPEN","isDraft":true"#).stateWords == "draft")
        #expect(try pullRequest(#""number":1,"state":"OPEN","reviewDecision":"CHANGES_REQUESTED""#).stateWords
            == "open, changes requested")
        #expect(try pullRequest(#""number":1,"state":"CLOSED""#).stateWords == "closed")
    }

    // MARK: checks

    @Test func aSuccessfulCheckRunPasses() throws {
        let summary = try rollup(#"{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}"#)
        #expect(summary == ChecksSummary(passed: 1))
        #expect(summary.text == "1 passed")
    }

    @Test func aFailedCheckRunFails() throws {
        let summary = try rollup(#"{"status":"COMPLETED","conclusion":"FAILURE"}"#)
        #expect(summary == ChecksSummary(failed: 1))
    }

    @Test func aCheckRunInProgressIsPending() throws {
        #expect(try rollup(#"{"status":"IN_PROGRESS","conclusion":""}"#) == ChecksSummary(pending: 1))
    }

    @Test func aPendingStatusContextIsPendingAndASuccessOnePasses() throws {
        #expect(try rollup(#"{"__typename":"StatusContext","state":"PENDING"}"#) == ChecksSummary(pending: 1))
        #expect(try rollup(#"{"__typename":"StatusContext","state":"SUCCESS"}"#) == ChecksSummary(passed: 1))
        #expect(try rollup(#"{"__typename":"StatusContext","state":"ERROR"}"#) == ChecksSummary(failed: 1))
    }

    @Test func anUnknownShapeIsPendingNeverPassed() throws {
        let summary = try rollup(
            #"{"status":"COMPLETED","conclusion":"BRAND_NEW"},{"colour":"green"},{},"text",42,null,{"status":["x"]}"#)
        #expect(summary == ChecksSummary(pending: 7))
    }

    @Test(arguments: ["NEUTRAL", "SKIPPED"])
    func neutralAndSkippedPass(conclusion: String) throws {
        #expect(try rollup(#"{"status":"COMPLETED","conclusion":"\#(conclusion)"}"#) == ChecksSummary(passed: 1))
    }

    @Test(arguments: ["ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"])
    func theOtherBadConclusionsFail(conclusion: String) throws {
        #expect(try rollup(#"{"status":"COMPLETED","conclusion":"\#(conclusion)"}"#) == ChecksSummary(failed: 1))
    }

    @Test func aMixedRollupCountsEachKind() throws {
        let summary = try rollup(
            #"{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"FAILURE"},{"state":"PENDING"}"#)
        #expect(summary.text == "1 passed, 1 failed, 1 pending")
    }

    // MARK: choice

    private func pr(_ number: Int, _ state: String) -> PullRequest {
        PullRequest(
            number: number, url: "", state: state, isDraft: false, reviewDecision: "", title: "t",
            checks: ChecksSummary(), files: [], changedFiles: 0)
    }

    @Test func anOpenPullRequestBeatsAMergedOneEvenWithALowerNumber() {
        #expect(PullRequest.choose(from: [[pr(9, "MERGED")], [pr(3, "OPEN")]])?.number == 3)
    }

    @Test func twoMergedOnesChooseTheHigherNumber() {
        #expect(PullRequest.choose(from: [[pr(4, "MERGED"), pr(8, "MERGED")], [pr(6, "CLOSED")]])?.number == 8)
    }

    @Test func severalOpenOnesChooseTheHighestNumber() {
        #expect(PullRequest.choose(from: [[pr(2, "OPEN")], [pr(5, "OPEN"), pr(1, "MERGED")]])?.number == 5)
    }

    @Test func anEmptyListChoosesNothing() {
        #expect(PullRequest.choose(from: []) == nil)
        #expect(PullRequest.choose(from: [[], []]) == nil)
    }

    // MARK: files and URL

    @Test func aHundredFilesOfOneHundredFiftySetsTheCappedFlag() throws {
        let entries = (0..<100).map { #"{"path":"f\#($0)","additions":1,"deletions":0}"# }.joined(separator: ",")
        let pr = try pullRequest(#""number":1,"changedFiles":150,"files":[\#(entries)]"#)
        #expect(pr.files.count == 100)
        #expect(pr.filesCapped)
    }

    @Test(arguments: ["https://github.com/o/r/pull/1", "HTTPS://GitHub.com/o/r/pull/1"])
    func aGitHubHttpsUrlOpens(text: String) {
        #expect(PullRequest.openableURL(text) != nil)
    }

    @Test(arguments: [
        "http://github.com/o/r/pull/1", "javascript:alert(1)", "file:///etc/passwd",
        "https://github.com.evil.com/o/r/pull/1", "https://evil.com/github.com",
        "https://github.com@evil.com/o/r", "https://evil.com@github.com/o/r", "https://github.com:8443/o/r",
        "github.com/o/r/pull/1", "", "https://",
    ])
    func everyOtherUrlOpensNothing(text: String) {
        #expect(PullRequest.openableURL(text) == nil)
    }
}
