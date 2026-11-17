import Foundation
import Testing
@testable import OrchestratorGUI

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite @MainActor struct QuitModelTests {
    struct Boom: LocalizedError { var errorDescription: String? { "still busy" } }

    private func snapshot(_ names: [String]) -> TmuxSnapshot {
        TmuxSnapshot(
            sessions: [],
            windows: names.map { WindowEntry(session: $0, name: "dashboard", path: "/work/\($0)", activity: nil, paneId: "%1") },
            rows: names.map { SessionRow(id: $0, title: $0.uppercased()) })
    }

    private func model(_ names: [String], _ calls: Calls, failing: Set<String> = []) -> QuitModel {
        QuitModel(snapshot: snapshot(names)) { id, folder in
            calls.add("\(id)@\(folder)")
            if failing.contains(id) { throw Boom() }
        }
    }

    @Test func entriesStartUncheckedInRowOrder() {
        let model = model(["a", "b", "c"], Calls())
        #expect(model.entries.map(\.id) == ["a", "b", "c"])
        #expect(model.entries.allSatisfy { !$0.isChecked })
        #expect(model.entries.map(\.folder) == ["/work/a", "/work/b", "/work/c"])
    }

    @Test func togglingOneEntryLeavesTheOthers() {
        let model = model(["a", "b", "c"], Calls())
        model.setChecked("b", true)
        #expect(model.entries.map(\.isChecked) == [false, true, false])
    }

    @Test func confirmStopsOnlyTheCheckedEntry() async {
        let calls = Calls()
        let model = model(["a", "b", "c"], calls)
        model.setChecked("b", true)
        let failures = await model.confirm()
        #expect(calls.all == ["b@/work/b"])
        #expect(failures.isEmpty)
    }

    @Test func confirmWithNothingCheckedMakesNoCall() async {
        let calls = Calls()
        let failures = await model(["a", "b"], calls).confirm()
        #expect(calls.all.isEmpty)
        #expect(failures.isEmpty)
    }

    @Test func aFailureDoesNotStopTheNextCheckedEntry() async {
        let calls = Calls()
        let model = model(["a", "b"], calls, failing: ["a"])
        model.setChecked("a", true)
        model.setChecked("b", true)
        let failures = await model.confirm()
        #expect(calls.all == ["a@/work/a", "b@/work/b"])
        #expect(failures == [QuitFailure(title: "A", reason: "still busy")])
    }

    @Test func aSnapshotWithNoRowsGivesNoEntries() {
        #expect(model([], Calls()).entries.isEmpty)
    }
}
