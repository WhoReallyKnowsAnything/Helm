import Foundation
import Testing
@testable import OrchestratorGUI

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Holds a restore closure until the test opens it, so the test can look at the model while a run is in flight.
private actor Gate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}

@Suite @MainActor struct RestoreModelTests {
    struct Boom: LocalizedError { var errorDescription: String? { "no base session" } }

    private let a = OpenProject(id: "a", title: "A", folder: "/work/a")
    private let b = OpenProject(id: "b", title: "B", folder: "/work/b")

    private func model(
        _ calls: Calls, result: RestoreResult = RestoreResult(), fail: Bool = false, gate: Gate? = nil
    ) -> RestoreModel {
        RestoreModel(
            capture: { calls.add("capture"); return "env" },
            restore: { folder, env in
                calls.add("restore \(folder) \(env)")
                if let gate { await gate.wait() }
                if fail { throw Boom() }
                return result
            },
            refresh: { calls.add("refresh") })
    }

    @Test func creatingTheModelMakesNoCall() {
        let calls = Calls()
        let model = model(calls)
        #expect(model.running == nil && model.failure == nil && model.notice == nil)
        #expect(calls.all.isEmpty)
    }

    @Test func onePressCapturesRestoresThenRefreshesOnce() async {
        let calls = Calls()
        let model = model(calls)
        await model.press(a)
        #expect(calls.all == ["capture", "restore /work/a env", "refresh"])
        #expect(model.failure == nil && model.notice == nil)
    }

    @Test func aSecondPressWhileOneRunsDoesNothingAndRunningNamesTheProject() async {
        let calls = Calls()
        let gate = Gate()
        let model = model(calls, gate: gate)
        let first = Task { await model.press(a) }
        // `running` is set before capture and restore start, so wait for the restore call itself.
        while !calls.all.contains("restore /work/a env") { await Task.yield() }
        #expect(model.running == "a")
        await model.press(b)
        await model.press(a)
        #expect(calls.all == ["capture", "restore /work/a env"])
        await gate.open()
        await first.value
        #expect(model.running == nil)
        #expect(calls.all.last == "refresh")
    }

    @Test func aThrownErrorSetsAFailureAndSkipsRefresh() async {
        let calls = Calls()
        let model = model(calls, fail: true)
        await model.press(a)
        #expect(model.failure == QuitFailure(title: "A", reason: "no base session"))
        #expect(!calls.all.contains("refresh"))
        #expect(model.running == nil)
        model.dismissFailure()
        #expect(model.failure == nil)
    }

    @Test func skippedLinesBecomeANoticeOnePerLine() async {
        let calls = Calls()
        let model = model(calls, result: RestoreResult(
            resumed: ["resumed a"], skipped: ["skipped b: gone", "skipped c: no dir"]))
        await model.press(a)
        #expect(model.notice?.title.contains("A") == true)
        #expect(model.notice?.reason == "skipped b: gone\nskipped c: no dir")
        #expect(model.failure == nil)
        #expect(calls.all.last == "refresh")
        model.dismissNotice()
        #expect(model.notice == nil)
    }

    @Test(arguments: [(0, 0, nil), (3, 3, nil), (10, 10, nil), (25, 10, "and 15 more")] as [(Int, Int, String?)])
    func noticeListsTheLast10SkippedLinesAndCountsTheRest(total: Int, shown: Int, more: String?) async {
        let lines = (1...max(total, 1)).prefix(total).map { "skipped w\($0): gone" }
        let model = model(Calls(), result: RestoreResult(skipped: lines))
        await model.press(a)
        guard total > 0 else { #expect(model.notice == nil); return }
        let parts = model.notice?.reason.components(separatedBy: "\n") ?? []
        #expect(parts.filter { $0.hasPrefix("skipped ") } == Array(lines.suffix(shown)))
        #expect(parts.count == shown + (more == nil ? 0 : 1))
        if let more { #expect(parts.first == more) }
    }

    @Test func aCleanResultSetsNeitherAlert() async {
        let model = model(Calls(), result: RestoreResult(resumed: ["resumed a"]))
        await model.press(a)
        #expect(model.failure == nil && model.notice == nil)
    }
}
