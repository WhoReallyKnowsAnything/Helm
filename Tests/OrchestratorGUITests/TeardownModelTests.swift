import Foundation
import Testing
@testable import OrchestratorGUI

/// Counts what the stub steps were asked to do.
private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var _teardowns = 0, _kills = 0, _willRun = 0
    var teardowns: Int { lock.lock(); defer { lock.unlock() }; return _teardowns }
    var kills: Int { lock.lock(); defer { lock.unlock() }; return _kills }
    var willRun: Int { lock.lock(); defer { lock.unlock() }; return _willRun }
    func teardown() { lock.lock(); _teardowns += 1; lock.unlock() }
    func kill() { lock.lock(); _kills += 1; lock.unlock() }
    func fired() { lock.lock(); _willRun += 1; lock.unlock() }
}

private let refusal = "Error: session/alpha is not merged into main (no ancestry); nothing torn down\n"

@MainActor
struct TeardownModelTests {
    private func model(
        _ steps: Steps,
        teardown: MergeReview.Run = MergeReview.Run(output: "removed\n", status: 0),
        kill: MergeReview.Run = MergeReview.Run(output: "killed\n", status: 0),
        environment: @escaping @Sendable () throws -> [String: String] = { ["PATH": "/usr/bin"] },
        delay: TimeInterval = 0
    ) -> TeardownModel {
        TeardownModel(
            label: "alpha",
            captureEnvironment: environment,
            teardown: { _ in
                steps.teardown()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                return teardown
            },
            kill: { _ in steps.kill(); return kill },
            willRun: { steps.fired() })
    }

    private func outcome(_ model: TeardownModel) -> TeardownModel.Outcome? {
        if case .result(let outcome) = model.state { return outcome }
        return nil
    }

    @Test func aDoneTeardownRunsOnceAndNoKill() async {
        let steps = Steps()
        let model = model(steps)
        await model.confirm()
        #expect(steps.teardowns == 1 && steps.kills == 0)
        #expect(outcome(model)?.succeeded == true)
        #expect(outcome(model)?.killed == false)
        #expect(outcome(model)?.output == "removed\n")
    }

    @Test func cancelAtTheFirstQuestionMakesNoRun() {
        let steps = Steps()
        let model = model(steps)
        #expect(model.state == .asking)
        #expect(steps.teardowns == 0 && steps.kills == 0 && steps.willRun == 0)
    }

    @Test func aNotMergedResultShowsTheSecondQuestionAndRunsNoKill() async {
        let steps = Steps()
        let model = model(steps, teardown: MergeReview.Run(output: refusal, status: 1))
        await model.confirm()
        #expect(model.state == .askingKill(output: refusal))
        #expect(steps.kills == 0)
    }

    @Test func cancelAtTheSecondQuestionLeavesNoKill() async {
        let steps = Steps()
        let model = model(steps, teardown: MergeReview.Run(output: refusal, status: 1))
        await model.confirm()
        #expect(steps.kills == 0 && steps.teardowns == 1)
    }

    @Test func confirmAtTheSecondQuestionMakesExactlyOneKill() async {
        let steps = Steps()
        let model = model(steps, teardown: MergeReview.Run(output: refusal, status: 1))
        await model.confirm()
        await model.confirmKill()
        await model.confirmKill()
        #expect(steps.kills == 1)
        #expect(outcome(model)?.succeeded == true)
        #expect(outcome(model)?.killed == true)
        #expect(outcome(model)?.detail?.contains("orphaned") == true)
    }

    @Test func theKillCannotRunWithoutTheSecondQuestion() async {
        let steps = Steps()
        let model = model(steps)
        await model.confirmKill()
        #expect(steps.kills == 0)
        #expect(model.state == .asking)
    }

    @Test func anotherFailureShowsItsTextAndNoSecondQuestion() async {
        let steps = Steps()
        let model = model(steps, teardown: MergeReview.Run(output: "Error: another merge-review is in progress\n", status: 1))
        await model.confirm()
        #expect(outcome(model)?.succeeded == false)
        #expect(outcome(model)?.output == "Error: another merge-review is in progress\n")
        await model.confirmKill()
        #expect(steps.kills == 0)
    }

    @Test func aStoppedTeardownIsFailedWithItsText() async {
        let steps = Steps()
        let model = model(steps, teardown: MergeReview.Run(output: "partial\n", status: 15, failure: .timedOut(seconds: 300)))
        await model.confirm()
        #expect(outcome(model)?.succeeded == false)
        #expect(outcome(model)?.detail?.contains("stopped") == true)
    }

    @Test func aFailedKillIsFailed() async {
        let steps = Steps()
        let model = model(steps, teardown: MergeReview.Run(output: refusal, status: 1), kill: MergeReview.Run(output: "no sessions table\n", status: 1))
        await model.confirm()
        await model.confirmKill()
        #expect(outcome(model)?.succeeded == false)
        #expect(outcome(model)?.killed == true)
        #expect(outcome(model)?.output == "no sessions table\n")
    }

    @Test func aFailedEnvironmentCaptureIsShownAndRunsNothing() async {
        struct Boom: LocalizedError { var errorDescription: String? { "no PATH" } }
        let steps = Steps()
        let model = model(steps, environment: { throw Boom() })
        await model.confirm()
        #expect(outcome(model)?.detail == "no PATH")
        #expect(steps.teardowns == 0 && steps.willRun == 0)
    }

    @Test func theWillRunCallbackFiresOncePerRun() async {
        let steps = Steps()
        let model = model(steps, teardown: MergeReview.Run(output: refusal, status: 1))
        await model.confirm()
        #expect(steps.willRun == 1)
        await model.confirmKill()
        #expect(steps.willRun == 2)
    }

    @Test func twoRapidConfirmTapsMakeOneRun() async {
        let steps = Steps()
        let model = model(steps, delay: 0.2)
        async let first: Void = model.confirm()
        async let second: Void = model.confirm()
        _ = await (first, second)
        #expect(steps.teardowns == 1)
    }
}
