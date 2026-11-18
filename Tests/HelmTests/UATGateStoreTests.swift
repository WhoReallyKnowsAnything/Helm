import Foundation
import Testing
@testable import Helm

private final class GateCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@MainActor @Suite(.serialized) struct UATGateStoreTests {
    private func project() throws -> (root: String, worktree: String) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory() + "uat-gate-store-" + UUID().uuidString.prefix(8).lowercased())
        let wt = base.appendingPathComponent(".claude/worktrees/cad-verify-p3")
        try FileManager.default.createDirectory(at: wt.appendingPathComponent(".planning/phases/3"), withIntermediateDirectories: true)
        return (base.resolvingSymlinksInPath().path, wt.resolvingSymlinksInPath().path)
    }

    private func row(_ label: String, _ worktree: String?, lastEvent: String? = "done") -> WorkerRow {
        WorkerRow(agentId: label, status: "running", taskTitle: nil, lastEvent: lastEvent, worktreePath: worktree)
    }

    private func wait(_ store: UATGateStore, until verdict: UATGate.Verdict) async throws {
        for _ in 0..<500 where store.verdict != verdict { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func skippedConfirmationNamesTheCount() {
        #expect(UATGateStore.skippedConfirmation(1) == "1 item was skipped. Merge anyway?")
        #expect(UATGateStore.skippedConfirmation(3) == "3 items were skipped. Merge anyway?")
    }

    @Test func verifyLabelPublishesCheckingThenTheVerdict() async throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p.root) }
        let store = UATGateStore(check: { _, _ in Thread.sleep(forTimeInterval: 0.2); return .allowed })
        store.point(project: p.root, row: row("cad-verify-p3", p.worktree))
        #expect(store.verdict == .checking)
        try await wait(store, until: .allowed)
        #expect(store.verdict == .allowed)
    }

    @Test func otherLabelIsNotGatedAndNeverChecked() async throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p.root) }
        let calls = GateCalls()
        let store = UATGateStore(check: { _, _ in _ = calls.next(); return .allowed })
        store.point(project: p.root, row: row("cad-execute-p1", p.worktree))
        store.recheck()
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.verdict == .notGated && calls.count == 0)
    }

    @Test func aRowChangeChecksAgainAndTheSameRowDoesNot() async throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p.root) }
        let calls = GateCalls()
        let store = UATGateStore(check: { _, _ in _ = calls.next(); return .allowed })
        store.point(project: p.root, row: row("cad-verify-p3", p.worktree, lastEvent: nil))
        try await wait(store, until: .allowed)
        store.point(project: p.root, row: row("cad-verify-p3", p.worktree, lastEvent: nil))
        store.point(project: p.root, row: row("cad-verify-p3", p.worktree, lastEvent: "done"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.count == 2)
    }

    @Test func aSlowFirstRunNeverOverwritesTheSecond() async throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p.root) }
        let order = GateCalls()
        let store = UATGateStore(check: { _, _ in
            if order.next() == 1 { Thread.sleep(forTimeInterval: 0.6); return .blocked("old") }
            return .allowed
        })
        store.point(project: p.root, row: row("cad-verify-p3", p.worktree, lastEvent: nil))
        store.recheck()
        try await wait(store, until: .allowed)
        try await Task.sleep(for: .milliseconds(900))
        #expect(store.verdict == .allowed)
    }

    @Test func writingTheWorktreeUatRechecksAndAnOldWorktreeWriteDoesNot() async throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p.root) }
        let calls = GateCalls()
        let store = UATGateStore(check: { _, _ in _ = calls.next(); return .allowed })
        store.point(project: p.root, row: row("cad-verify-p3", p.worktree))
        try await wait(store, until: .allowed)
        try await Task.sleep(for: .milliseconds(800))
        let before = calls.count
        let file = p.worktree + "/.planning/phases/3/UAT.md"
        try "a".write(toFile: file, atomically: true, encoding: .utf8)
        for _ in 0..<500 where calls.count == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls.count > before)

        store.point(project: p.root, row: row("cad-execute-p1", p.worktree))
        try await Task.sleep(for: .milliseconds(800))
        let after = calls.count
        try "b".write(toFile: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(calls.count == after && store.verdict == .notGated)
    }

    @Test func aGrantMakesTheEffectiveVerdictAllowedForThatLabelOnly() async throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p.root) }
        let store = UATGateStore(check: { _, _ in .blocked("UAT partial") })
        store.point(project: p.root, row: row("cad-verify-p3", p.worktree))
        try await wait(store, until: .blocked("UAT partial"))
        #expect(store.effective(granted: ["cad-verify-p3"]) == .allowed)
        #expect(store.effective(granted: ["cad-verify-p4"]) == .blocked("UAT partial"))
        #expect(store.effective(granted: []) == .blocked("UAT partial"))
        let actions = WorkerActions(row: row("cad-verify-p3", p.worktree), uat: store.effective(granted: ["cad-verify-p3"]))
        #expect(actions.mergeEnabled)
    }
}
