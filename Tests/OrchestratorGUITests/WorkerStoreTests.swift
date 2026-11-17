import Combine
import Foundation
import Testing
@testable import OrchestratorGUI

/// A scripted reader. `read()` returns the next scripted result, then repeats the last one. When `gate` is set,
/// the first read blocks on it. All state sits behind a lock, because reads run on the store's queue.
final class FakeSource: WorkerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [WorkerRead]
    private var _reads = 0
    private var _closed = false
    let gate: DispatchSemaphore?

    init(_ script: [WorkerRead], gate: DispatchSemaphore? = nil) {
        self.script = script
        self.gate = gate
    }

    var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    func set(_ next: [WorkerRead]) { lock.lock(); script = next; lock.unlock() }

    func read() -> WorkerRead {
        lock.lock()
        _reads += 1
        let first = _reads == 1
        let result = script.count > 1 ? script.removeFirst() : script[0]
        lock.unlock()
        if first { gate?.wait() }
        return result
    }

    func close() { lock.lock(); _closed = true; lock.unlock() }
}

private func state(_ ids: [String], status: String = "running") -> WorkerRead {
    .loaded(WorkerState(rows: ids.map { WorkerRow(agentId: $0, status: status, taskTitle: nil, lastEvent: nil) }))
}

/// Polls up to 3 seconds. Test code only.
@MainActor func settle(_ done: @MainActor () -> Bool) async {
    for _ in 0..<300 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite(.serialized) @MainActor struct WorkerStoreTests {
    @Test func fixtureProjectGivesFourRowsInOrder() async throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let store = WorkerStore()
        store.point(at: fx.path)
        await settle { store.result != nil }
        guard case .loaded(let loaded) = store.result else { Issue.record("not loaded: \(String(describing: store.result))"); return }
        #expect(loaded.rows.map(\.agentId) == ["alpha", "bravo", "charlie", "delta"])
        store.point(at: nil)
    }

    @Test func folderWithoutClaudeGivesNoStateAndCreatesNothing() async throws {
        let fx = try FixtureProject.make(withDatabase: false)
        defer { fx.remove() }
        let store = WorkerStore()
        store.point(at: fx.path)
        await settle { store.result != nil }
        #expect(store.result == .noDatabase)
        #expect(!WorkerFiles.exists(fx.path + "/.claude"))
        store.point(at: nil)
    }

    @Test func unchangedReadPublishesNothingAndChangedReadPublishesOnce() async {
        let source = FakeSource([state(["a"])])
        let store = WorkerStore(makeSource: { _ in source })
        var sends = 0
        let sink = store.objectWillChange.sink { sends += 1 }
        defer { sink.cancel() }
        store.point(at: "/p")
        await settle { source.reads == 1 && store.result != nil }
        let afterFirst = sends

        store.requestRead()
        await settle { source.reads == 2 }
        store.requestRead()
        await settle { source.reads == 3 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sends == afterFirst)

        source.set([state(["a"], status: "blocked")])
        store.requestRead()
        await settle { source.reads == 4 && store.result == state(["a"], status: "blocked") }
        #expect(sends == afterFirst + 1)
    }

    @Test func failingReaderKeepsLastRowsAndSetsFailureText() async {
        let source = FakeSource([state(["a", "b"])])
        let store = WorkerStore(makeSource: { _ in source })
        store.point(at: "/p")
        await settle { store.result != nil }
        source.set([.failed("SQLite error 5: database is locked")])
        store.requestRead()
        await settle { store.failure != nil }
        #expect(store.failure == "SQLite error 5: database is locked")
        #expect(store.result == state(["a", "b"]))
        source.set([state(["a", "b"])])
        store.requestRead()
        await settle { store.failure == nil }
        #expect(store.failure == nil)
    }

    @Test func pointingElsewhereClosesTheFirstReaderAndLoadsTheSecond() async {
        let first = FakeSource([state(["one"])]), second = FakeSource([state(["two"])])
        let store = WorkerStore(makeSource: { $0 == "/first" ? first : second })
        store.point(at: "/first")
        await settle { store.result == state(["one"]) }
        store.point(at: "/second")
        await settle { store.result == state(["two"]) && first.closed }
        #expect(first.closed)
        #expect(!second.closed)
        #expect(store.result == state(["two"]))
        store.point(at: nil)
        await settle { second.closed }
        #expect(second.closed)
        #expect(store.result == nil)
    }

    @Test func requestDuringABlockedReadProducesExactlyOneFollowUpRead() async {
        let gate = DispatchSemaphore(value: 0)
        let source = FakeSource([state(["a"])], gate: gate)
        let store = WorkerStore(makeSource: { _ in source })
        store.point(at: "/p")
        await settle { source.reads == 1 }
        store.requestRead()
        store.requestRead()
        store.requestRead()
        gate.signal()
        await settle { source.reads == 2 && store.result != nil }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(source.reads == 2)
    }

    @Test func statusChangedWithTheSqliteCliPublishesWithinTwoSeconds() async throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let store = WorkerStore()
        store.point(at: fx.path)
        await settle { store.result != nil }
        try fx.sql("update sessions set status='blocked' where agent_id='alpha'")
        let start = ContinuousClock.now
        await settle { alphaStatus(store) == "blocked" }
        #expect(alphaStatus(store) == "blocked")
        #expect(ContinuousClock.now - start < .seconds(2))
        store.point(at: nil)
    }

    @Test func idleProjectWithSidecarFilesAddsAtMostTwoReads() async throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        #expect(WorkerFiles.exists(fx.dbPath + "-wal") && WorkerFiles.exists(fx.dbPath + "-shm"))
        let source = CountingSource(WorkerDatabase(project: fx.path))
        let store = WorkerStore(makeSource: { _ in source })
        store.point(at: fx.path)
        await settle { store.result != nil }
        let settled = source.reads
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(source.reads - settled <= 2)
        store.point(at: nil)
    }
}

@MainActor private func alphaStatus(_ store: WorkerStore) -> String? {
    guard case .loaded(let loaded) = store.result else { return nil }
    return loaded.rows.first { $0.agentId == "alpha" }?.status
}

/// Wraps a real reader and counts its reads.
final class CountingSource: WorkerSource, @unchecked Sendable {
    private let inner: WorkerSource
    private let counter = Counter()
    init(_ inner: WorkerSource) { self.inner = inner }
    var reads: Int { counter.value }
    func read() -> WorkerRead { counter.bump(); return inner.read() }
    func close() { inner.close() }
}
