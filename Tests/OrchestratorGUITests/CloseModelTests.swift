import Foundation
import Testing
@testable import OrchestratorGUI

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite @MainActor struct CloseModelTests {
    struct Boom: LocalizedError { var errorDescription: String? { "still running" } }

    private let snapshot: TmuxSnapshot

    init() {
        snapshot = TmuxSnapshot(
            sessions: [],
            windows: [
                WindowEntry(session: "a", name: "dashboard", path: "/work/a", activity: nil, paneId: "%1"),
                WindowEntry(session: "a", name: "w1", path: "/work/a", activity: nil, paneId: "%2"),
                WindowEntry(session: "a", name: "w2", path: "/work/a", activity: nil, paneId: "%3"),
                WindowEntry(session: "b", name: "dashboard", path: "/work/b", activity: nil, paneId: "%4"),
            ],
            rows: [SessionRow(id: "a", title: "A"), SessionRow(id: "b", title: "B")])
    }

    private func model(_ calls: Calls, fail: Bool = false) -> CloseModel {
        CloseModel { id, folder in
            calls.add("\(id)@\(folder)")
            if fail { throw Boom() }
        }
    }

    @Test func askingMakesNoCallAndCountsLiveWorkers() {
        let calls = Calls()
        let model = model(calls)
        model.ask(SessionRow(id: "a", title: "A"), in: snapshot)
        #expect(model.pending == CloseRequest(id: "a", title: "A", folder: "/work/a", liveWorkers: 2))
        #expect(calls.all.isEmpty)
    }

    @Test func cancelMakesNoCall() async {
        let calls = Calls()
        let model = model(calls)
        model.ask(SessionRow(id: "b", title: "B"), in: snapshot)
        model.cancel()
        #expect(model.pending == nil)
        #expect(await model.confirm(model.take()) == nil)
        #expect(calls.all.isEmpty)
    }

    @Test func confirmStopsThatProjectOnceAndReturnsItsId() async {
        let calls = Calls()
        let model = model(calls)
        model.ask(SessionRow(id: "b", title: "B"), in: snapshot)
        #expect(await model.confirm(model.take()) == "b")
        #expect(calls.all == ["b@/work/b"])
        #expect(model.pending == nil)
        #expect(model.failure == nil)
    }

    @Test func confirmStillStopsWhenTheAlertDismissesFirst() async {
        let calls = Calls()
        let model = model(calls)
        model.ask(SessionRow(id: "b", title: "B"), in: snapshot)
        let request = model.take()
        model.cancel()
        #expect(await model.confirm(request) == "b")
        #expect(calls.all == ["b@/work/b"])
    }

    @Test func aFailureKeepsItsReasonAndReturnsNoId() async {
        let model = model(Calls(), fail: true)
        model.ask(SessionRow(id: "a", title: "A"), in: snapshot)
        #expect(await model.confirm(model.take()) == nil)
        #expect(model.failure == QuitFailure(title: "A (session a)", reason: "still running"))
        model.dismissFailure()
        #expect(model.failure == nil)
    }

    @Test func failureNamesTheSessionWhenTheTitleDiffers() async {
        let model = model(Calls(), fail: true)
        let request = CloseRequest(id: "fxc", title: "fxother", folder: "/work/fxother", liveWorkers: 0)
        #expect(await model.confirm(request) == nil)
        #expect(model.failure == QuitFailure(title: "fxother (session fxc)", reason: "still running"))
    }

    @Test func failureTitleIsOnlyTheTitleWhenItMatchesTheSession() async {
        let model = model(Calls(), fail: true)
        let request = CloseRequest(id: "fxc", title: "fxc", folder: "/work/fxc", liveWorkers: 0)
        #expect(await model.confirm(request) == nil)
        #expect(model.failure == QuitFailure(title: "fxc", reason: "still running"))
    }

    @Test func messageNamesLiveWorkersOnlyWhenThereAreSome() {
        #expect(CloseRequest(id: "a", title: "A", folder: "/f", liveWorkers: 2).message.contains("2 live workers"))
        #expect(CloseRequest(id: "a", title: "A", folder: "/f", liveWorkers: 1).message.contains("1 live worker "))
        #expect(!CloseRequest(id: "a", title: "A", folder: "/f", liveWorkers: 0).message.contains("worker"))
    }

    private func forgettingModel(_ calls: Calls, fail: Bool = false) -> CloseModel {
        CloseModel(
            teardown: { id, folder in
                calls.add("teardown \(id)@\(folder)")
                if fail { throw Boom() }
            },
            forget: { id in calls.add("forget \(id)") })
    }

    @Test func confirmForgetsTheProjectOnceAfterTheTeardown() async {
        let calls = Calls()
        let model = forgettingModel(calls)
        model.ask(SessionRow(id: "b", title: "B"), in: snapshot)
        #expect(await model.confirm(model.take()) == "b")
        #expect(calls.all == ["teardown b@/work/b", "forget b"])
    }

    @Test func cancelDoesNotForgetTheProject() async {
        let calls = Calls()
        let model = forgettingModel(calls)
        model.ask(SessionRow(id: "b", title: "B"), in: snapshot)
        model.cancel()
        #expect(await model.confirm(model.take()) == nil)
        #expect(calls.all.isEmpty)
    }

    @Test func aFailedTeardownDoesNotForgetTheProject() async {
        let calls = Calls()
        let model = forgettingModel(calls, fail: true)
        model.ask(SessionRow(id: "a", title: "A"), in: snapshot)
        #expect(await model.confirm(model.take()) == nil)
        #expect(calls.all == ["teardown a@/work/a"])
    }
}
