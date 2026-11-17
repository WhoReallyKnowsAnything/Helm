import Foundation
import Testing
@testable import OrchestratorGUI

/// Counts and records what the stub steps were asked to do.
private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var _previews = 0, _merges = 0, _willRun = 0, _lines: [String] = []
    private var reads: [WorkerRead]
    init(reads: [WorkerRead]) { self.reads = reads }

    var previews: Int { lock.lock(); defer { lock.unlock() }; return _previews }
    var merges: Int { lock.lock(); defer { lock.unlock() }; return _merges }
    var willRun: Int { lock.lock(); defer { lock.unlock() }; return _willRun }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    func preview() { lock.lock(); _previews += 1; lock.unlock() }
    func merge() { lock.lock(); _merges += 1; lock.unlock() }
    func fired() { lock.lock(); _willRun += 1; lock.unlock() }
    func add(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
    /// Each read pops the next value; the last one repeats.
    func nextRead() -> WorkerRead {
        lock.lock(); defer { lock.unlock() }
        return reads.count > 1 ? reads.removeFirst() : reads[0]
    }
}

private func row(_ status: String, event: String?, title: String? = "Fix login") -> WorkerRead {
    .loaded(WorkerState(rows: [WorkerRow(agentId: "alpha", status: status, taskTitle: title, lastEvent: event)]))
}

private let finished = row("running", event: "done")
private let merged = row("merged", event: "done")
private let marker = "✓ Merge complete: session/alpha → main\n"

@MainActor
struct MergeModelTests {
    private func model(
        _ steps: Steps, title: String? = "Fix login",
        preview: MergeReview.Run = MergeReview.Run(output: "b.txt | 1 +\n", status: 0),
        merge: MergeReview.Run = MergeReview.Run(output: marker, status: 0),
        environment: @escaping @Sendable () throws -> [String: String] = { ["PATH": "/usr/bin"] },
        notice: InboxDelivery.Outcome = .sent, mergeDelay: TimeInterval = 0,
        check: (@Sendable () -> PullRequestLookupResult)? = nil, allowUnknown: Bool = false,
        uat: (@Sendable () -> UATGate.Verdict)? = nil
    ) -> MergeModel {
        MergeModel(
            label: "alpha", title: title,
            readRow: { steps.nextRead() },
            captureEnvironment: environment,
            preview: { _ in steps.preview(); return preview },
            merge: { _ in
                steps.merge()
                if mergeDelay > 0 { Thread.sleep(forTimeInterval: mergeDelay) }
                return merge
            },
            deliver: { steps.add($0); return notice },
            willRun: { steps.fired() },
            pullRequestCheck: check, unknownPullRequestAllowed: allowUnknown, uatGate: uat)
    }

    private func outcome(_ model: MergeModel) -> MergeModel.Outcome? {
        if case .result(let outcome) = model.state { return outcome }
        return nil
    }

    @Test func aFinishedRowRunsThePreviewOnceAndNoMerge() async {
        let steps = Steps(reads: [finished])
        let model = model(steps)
        await model.open()
        await model.open()
        #expect(model.state == .preview(output: "b.txt | 1 +\n", canConfirm: true))
        #expect(steps.previews == 1)
        #expect(steps.merges == 0)
    }

    @Test func cancelLeavesOnlyThePreviewRun() async {
        let steps = Steps(reads: [finished])
        let model = model(steps)
        await model.open()
        #expect(steps.previews == 1 && steps.merges == 0 && steps.willRun == 0 && steps.lines.isEmpty)
    }

    @Test(arguments: [("running", Optional<String>.none), ("running", "blocked"), ("stalled", "done"), ("dead", "done"), ("merged", "done")])
    func aRowThatIsNotFinishedRunsNothingAtOpen(status: String, event: String?) async {
        let steps = Steps(reads: [row(status, event: event)])
        let model = model(steps)
        await model.open()
        guard case .refused = model.state else { Issue.record("expected a refusal, got \(model.state)"); return }
        #expect(steps.previews == 0 && steps.merges == 0)
    }

    @Test func aMissingRowAndAnUnreadableDatabaseRunNothing() async {
        for read in [WorkerRead.noDatabase, .noState, .permissionDenied, .failed("boom"), .loaded(WorkerState(rows: []))] {
            let steps = Steps(reads: [read])
            let model = model(steps)
            await model.open()
            guard case .refused = model.state else { Issue.record("expected a refusal for \(read)"); return }
            #expect(steps.previews == 0 && steps.merges == 0)
        }
    }

    @Test func aFailedEnvironmentCaptureIsShownAndRunsNothing() async {
        struct Boom: LocalizedError { var errorDescription: String? { "no PATH" } }
        let steps = Steps(reads: [finished])
        let model = model(steps, environment: { throw Boom() })
        await model.open()
        #expect(model.state == .refused("no PATH"))
        #expect(steps.previews == 0 && steps.merges == 0)
    }

    @Test func aFailedPreviewShowsItsOutputAndOffersNoConfirm() async {
        let steps = Steps(reads: [finished])
        let model = model(steps, preview: MergeReview.Run(output: "conflict\n", status: 1))
        await model.open()
        #expect(model.state == .preview(output: "conflict\n", canConfirm: false))
        await model.confirm()
        #expect(steps.merges == 0)
    }

    @Test func confirmRunsTheMergeOnceAndTheCallbackFiredBeforeIt() async {
        let steps = Steps(reads: [finished, finished, merged])
        let fired = FiredBefore()
        let model = MergeModel(
            label: "alpha", title: "Fix login",
            readRow: { steps.nextRead() },
            captureEnvironment: { [:] },
            preview: { _ in MergeReview.Run(output: "p", status: 0) },
            merge: { _ in fired.mergeStarted(callbacks: steps.willRun); steps.merge(); return MergeReview.Run(output: marker, status: 0) },
            deliver: { _ in .sent },
            willRun: { steps.fired() })
        await model.open()
        await model.confirm()
        #expect(steps.merges == 1)
        #expect(steps.willRun == 1)
        #expect(fired.callbacksAtMergeStart == 1)
        #expect(outcome(model)?.verdict == .merged)
    }

    @Test func aRowThatFlipsToWorkingBetweenPreviewAndConfirmRunsNoMerge() async {
        let steps = Steps(reads: [finished, row("running", event: "working")])
        let model = model(steps)
        await model.open()
        await model.confirm()
        guard case .refused = model.state else { Issue.record("expected a refusal, got \(model.state)"); return }
        #expect(steps.merges == 0 && steps.willRun == 0 && steps.lines.isEmpty)
    }

    @Test func theMarkerWithTheRowStillRunningIsNotMerged() async {
        let steps = Steps(reads: [finished])
        let model = model(steps)
        await model.open()
        await model.confirm()
        let result = outcome(model)
        #expect(result?.verdict == .failed)
        #expect(result?.detail == "The output says merged but the project database does not show it.")
        #expect(steps.lines.isEmpty)
    }

    @Test func mergeCancelledWithExitZeroIsNotMerged() async {
        let steps = Steps(reads: [finished, finished, merged])
        let model = model(steps, merge: MergeReview.Run(output: "Merge cancelled.\n", status: 0))
        await model.open()
        await model.confirm()
        #expect(outcome(model)?.verdict == .notMerged)
        #expect(steps.lines.isEmpty)
    }

    @Test func exitOneIsFailedWithTheFullOutput() async {
        let steps = Steps(reads: [finished])
        let model = model(steps, merge: MergeReview.Run(output: "Error: another merge-review for alpha is in progress\n", status: 1))
        await model.open()
        await model.confirm()
        let result = outcome(model)
        #expect(result?.verdict == .failed)
        #expect(result?.status == 1)
        #expect(result?.output == "Error: another merge-review for alpha is in progress\n")
        #expect(steps.lines.isEmpty)
    }

    @Test func aStoppedRunIsFailedWithItsText() async {
        let steps = Steps(reads: [finished])
        let model = model(steps, merge: MergeReview.Run(output: "partial\n", status: 15, failure: .timedOut(seconds: 600)))
        await model.open()
        await model.confirm()
        #expect(outcome(model)?.verdict == .failed)
        #expect(outcome(model)?.detail?.contains("stopped") == true)
    }

    @Test func aMergedRunDeliversExactlyOneCleanLine() async {
        let steps = Steps(reads: [finished, finished, merged])
        let model = model(steps, title: "a;b\nc")
        await model.open()
        await model.confirm()
        #expect(steps.lines == ["merge-review merged alpha (task: a;b c)"])
        #expect(outcome(model)?.verdict == .merged)
        #expect(outcome(model)?.notice == "Notice sent: merge-review merged alpha (task: a;b c)")
    }

    @Test func noTitleLeavesOutTheTaskPart() async {
        let steps = Steps(reads: [finished, finished, merged])
        let model = model(steps, title: nil)
        await model.open()
        await model.confirm()
        #expect(steps.lines == ["merge-review merged alpha"])
    }

    @Test func aRefusedNoticeLeavesTheVerdictMergedAndAddsTheReason() async {
        let steps = Steps(reads: [finished, finished, merged])
        let model = model(steps, notice: .refused("The orchestrator input line is not empty. Clear it and try again. Nothing was sent."))
        await model.open()
        await model.confirm()
        let result = outcome(model)
        #expect(result?.verdict == .merged)
        #expect(result?.notice == "Notice not sent: The orchestrator input line is not empty. Clear it and try again. Nothing was sent.\nmerge-review merged alpha (task: Fix login)")
        #expect(steps.lines.count == 1)
    }

    @Test func aFailedNoticeAlsoLeavesTheVerdictMerged() async {
        let steps = Steps(reads: [finished, finished, merged])
        let model = model(steps, notice: .failed("tmux not found"))
        await model.open()
        await model.confirm()
        #expect(outcome(model)?.verdict == .merged)
        #expect(outcome(model)?.notice?.hasPrefix("Notice not sent: tmux not found") == true)
    }

    @Test func twoQuickConfirmsRunOneMerge() async {
        let steps = Steps(reads: [finished, finished, merged])
        let model = model(steps, mergeDelay: 0.2)
        await model.open()
        async let first: Void = model.confirm()
        async let second: Void = model.confirm()
        _ = await (first, second)
        #expect(steps.merges == 1)
        #expect(steps.lines.count == 1)
    }

    // MARK: confirm-time pull request check (D-05)

    private func pullRequest(_ number: Int, _ state: String, draft: Bool = false) -> PullRequest {
        PullRequest(
            number: number, url: "", state: state, isDraft: draft, reviewDecision: "", title: "t",
            checks: ChecksSummary(), files: [], changedFiles: 0)
    }

    /// Opens, confirms, and returns the model and steps after the confirm.
    private func confirmed(
        _ result: PullRequestLookupResult, allowUnknown: Bool = false
    ) async -> (MergeModel, Steps) {
        let steps = Steps(reads: [finished, finished, merged])
        let model = model(steps, check: { result }, allowUnknown: allowUnknown)
        await model.open()
        await model.confirm()
        return (model, steps)
    }

    @Test(arguments: [false, true])
    func anOpenPullRequestRefusesTheMergeEvenWhenUnknownIsAllowed(draft: Bool) async {
        let (model, steps) = await confirmed(.found(pullRequest(7, "OPEN", draft: draft)), allowUnknown: true)
        #expect(model.state == .refused("PR #7 is open. Ask the orchestrator to merge it."))
        #expect(steps.merges == 0 && steps.willRun == 0 && steps.lines.isEmpty)
    }

    @Test func aFailedCheckRefusesWhenUnknownIsNotAllowed() async {
        let (model, steps) = await confirmed(.failed("gh: not logged in"))
        #expect(model.state == .refused("pull request lookup failed: gh: not logged in"))
        #expect(steps.merges == 0 && steps.willRun == 0)
    }

    @Test func aFailedCheckRunsTheMergeWhenUnknownIsAllowed() async {
        let (model, steps) = await confirmed(.failed("gh: not logged in"), allowUnknown: true)
        #expect(steps.merges == 1 && steps.willRun == 1)
        #expect(outcome(model)?.verdict == .merged)
    }

    @Test(arguments: [PullRequestLookupResult.noPullRequest, .found(PullRequest(
        number: 2, url: "", state: "MERGED", isDraft: false, reviewDecision: "", title: "t",
        checks: ChecksSummary(), files: [], changedFiles: 0)), .found(PullRequest(
        number: 3, url: "", state: "CLOSED", isDraft: false, reviewDecision: "", title: "t",
        checks: ChecksSummary(), files: [], changedFiles: 0))])
    func noPullRequestOrAMergedOrClosedOneRunsTheMerge(result: PullRequestLookupResult) async {
        let (_, steps) = await confirmed(result)
        #expect(steps.merges == 1 && steps.willRun == 1)
    }

    @Test func noCheckClosureKeepsThePlanTwoBehaviour() async {
        let steps = Steps(reads: [finished, finished, merged])
        let model = model(steps)
        await model.open()
        await model.confirm()
        #expect(steps.merges == 1 && steps.willRun == 1)
    }

    @Test func theCheckRunsAfterTheFreshRowReadSoAnUnfinishedRowStillRefusesFirst() async {
        let steps = Steps(reads: [finished, row("running", event: "working")])
        let open = pullRequest(1, "OPEN")
        let model = model(steps, check: { .found(open) })
        await model.open()
        await model.confirm()
        guard case .refused(let text) = model.state else { Issue.record("expected a refusal"); return }
        #expect(text.contains("not finished"))
        #expect(steps.merges == 0)
    }

    // MARK: G3 (UAT gate)

    @Test func aBlockedUatAtOpenRefusesAndRunsNoPreview() async {
        let steps = Steps(reads: [finished])
        let model = model(steps, uat: { .blocked("UAT is not complete: 1 pending") })
        await model.open()
        #expect(model.state == .refused("Merge is off: UAT is not complete: 1 pending. Nothing was run."))
        #expect(steps.previews == 0 && steps.merges == 0)
    }

    @Test func aCheckingUatAtOpenRefuses() async {
        let steps = Steps(reads: [finished])
        let model = model(steps, uat: { .checking })
        await model.open()
        #expect(model.state == .refused("Merge is off: checking UAT. Nothing was run."))
        #expect(steps.previews == 0)
    }

    @Test func aUatThatTurnsPartialBeforeConfirmRunsNoMerge() async {
        let steps = Steps(reads: [finished])
        let seq = VerdictSequence([.allowed, .blocked("UAT is not complete: 1 fail")])
        let model = model(steps, uat: { seq.next() })
        await model.open()
        #expect(steps.previews == 1)
        await model.confirm()
        #expect(model.state == .refused("Merge is off: UAT is not complete: 1 fail. Nothing was run."))
        #expect(steps.merges == 0 && steps.willRun == 0)
    }

    @Test(arguments: [UATGate.Verdict.allowed, .confirmSkipped(1), .notGated])
    func anOpenUatGateLetsTheNormalFlowRun(verdict: UATGate.Verdict) async {
        let steps = Steps(reads: [finished, finished, merged])
        let model = model(steps, uat: { verdict })
        await model.open()
        await model.confirm()
        #expect(steps.previews == 1 && steps.merges == 1)
        #expect(outcome(model)?.verdict == .merged)
    }
}

private final class VerdictSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UATGate.Verdict]
    init(_ items: [UATGate.Verdict]) { self.items = items }
    func next() -> UATGate.Verdict {
        lock.lock(); defer { lock.unlock() }
        return items.count > 1 ? items.removeFirst() : items[0]
    }
}

private final class FiredBefore: @unchecked Sendable {
    private(set) var callbacksAtMergeStart = -1
    func mergeStarted(callbacks: Int) { callbacksAtMergeStart = callbacks }
}
