import Foundation
import Testing
@testable import Helm

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String?] = []
    func add(_ p: String?) { lock.lock(); list.append(p); lock.unlock() }
    var all: [String?] { lock.lock(); defer { lock.unlock() }; return list }
}

private func okResult(_ phase: String?) -> RunRecordResult {
    RunRecordResult(
        render: RunRecordRender(file: phase ?? "all", roles: [], brackets: []),
        suggest: RunRecordSuggest(file: "f", scope: phase, eventsRead: 1, tweaks: [], receipts: []))
}

@MainActor @Suite(.serialized) struct RunRecordStoreTests {
    @Test func opensOnceThenRunsOnlyOnScopeChangeAndRefresh() async {
        let calls = Calls()
        let store = RunRecordStore(load: { _, phase in calls.add(phase); return okResult(phase) })
        await store.open(project: "/p")?.value
        #expect(calls.all == [nil])
        await store.select(phase: "1")?.value
        #expect(calls.all == [nil, "1"])
        await store.refresh()?.value
        #expect(calls.all == [nil, "1", "1"])
        #expect(store.result?.render?.file == "1" && store.phase == "1")
    }

    @Test func aFailureCarriesReasonsAndNoFigures() async {
        let store = RunRecordStore(load: { _, _ in RunRecordResult(reasons: ["render broke"]) })
        await store.open(project: "/p")?.value
        #expect(store.result?.reasons == ["render broke"] && store.result?.render == nil && store.result?.suggest == nil)
    }

    @Test func aSlowFirstLoadNeverReplacesTheSecond() async {
        let gate = DispatchSemaphore(value: 0)
        let store = RunRecordStore(load: { _, phase in
            if phase == nil { gate.wait() }
            return okResult(phase)
        })
        let first = store.open(project: "/p")
        await store.select(phase: "2")?.value
        gate.signal()
        await first?.value
        #expect(store.result?.render?.file == "2")
    }

    @Test func noProjectRunsNothing() {
        let calls = Calls()
        let store = RunRecordStore(load: { _, p in calls.add(p); return okResult(p) })
        #expect(store.open(project: nil) == nil)
        #expect(calls.all.isEmpty)
    }

    @Test func loadingChangesNothingUnderPlanning() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "rr-store-" + UUID().uuidString.prefix(8).lowercased())
        let planning = root.appendingPathComponent(".planning")
        try FileManager.default.createDirectory(at: planning, withIntermediateDirectories: true)
        try "{\"a\":1}\n".write(to: planning.appendingPathComponent("trace.jsonl"), atomically: true, encoding: .utf8)
        try "## Phases\n".write(to: planning.appendingPathComponent("ROADMAP.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        func snapshot() throws -> [String: Data] {
            var out: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: planning.path) {
                out[name] = try Data(contentsOf: planning.appendingPathComponent(name))
            }
            return out
        }
        let before = try snapshot()
        let store = RunRecordStore(load: { _, p in okResult(p) })
        await store.open(project: root.path)?.value
        await store.select(phase: "1")?.value
        await store.refresh()?.value
        #expect(try snapshot() == before)
    }
}
