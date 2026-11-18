import Combine
import Foundation
import Testing
@testable import Helm

private final class Runs: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@MainActor @Suite(.serialized) struct MilestoneScreenStoreTests {
    private static let pass = MilestoneAudit(counts: .init(total: 1, broken: 0, kinds: []), requirementBreaks: [],
                                             coverageBreaks: [], deferred: [], drift: nil)

    private func folder() throws -> String {
        let root = NSTemporaryDirectory() + "milestone-store-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    }

    private func store(_ runs: Runs) -> MilestoneScreenStore {
        MilestoneScreenStore(run: { _ in runs.bump(); return .success(Self.pass) })
    }

    @Test func pointLoadsOnceAndSamePointLoadsNothing() async throws {
        let p = try folder()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let runs = Runs()
        let s = store(runs)
        s.point(project: p)
        await s.reload()?.value
        let afterPoint = runs.count
        s.point(project: p)
        #expect(afterPoint >= 1)
        #expect(runs.count == afterPoint)
        #expect(s.result == .success(Self.pass))
    }

    @Test func refreshAndWorkerChangeEachLoadOnce() async throws {
        let runs = Runs()
        let s = store(runs)
        s.point(project: "/tmp")
        await s.reload()?.value
        let base = runs.count
        await s.reload()?.value
        #expect(runs.count == base + 1)
        await s.reload()?.value
        #expect(runs.count == base + 2)
    }

    private func landStore(origin: Runs, facts: Runs, find: Runs) -> MilestoneScreenStore {
        let reader = MilestoneLandReader(
            facts: { _, _ in facts.bump(); return .noWorktree },
            version: { _, _ in "4" },
            localTag: { _, _ in .absent },
            originTag: { _, _ in origin.bump(); return .absent },
            closed: { _, _ in .open })
        return MilestoneScreenStore(run: { _ in .success(Self.pass) }, land: reader,
                                    find: { _, _, _ in find.bump(); return .noPullRequest })
    }

    @Test func originRunsOnOpenAndRefreshOnlyAndPullRequestIsSelectedOncePerPoint() async throws {
        let (origin, facts, find) = (Runs(), Runs(), Runs())
        let s = landStore(origin: origin, facts: facts, find: find)
        s.point(project: "/tmp", worktree: nil, label: "cad-milestone-p3")
        await s.reload()?.value
        try await Task.sleep(for: .milliseconds(300))
        // The point's own load plus the awaited reload: origin ran for the point only.
        #expect(origin.count == 1)
        #expect(find.count == 1)
        let localBefore = facts.count
        await s.reload()?.value   // a .planning change or a worker-state change
        #expect(origin.count == 1)
        #expect(facts.count == localBefore + 1)
        s.refresh()
        await s.reload(origin: true)?.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(origin.count >= 2)
        s.point(project: "/tmp", worktree: nil, label: "cad-milestone-p3")
        #expect(find.count == 2)   // one select at the point, one lookup from Refresh; the same point selects nothing
    }

    @Test func reuseOfTheCachedOriginAnswerKeepsItAcrossLocalReloads() async throws {
        let (origin, facts, find) = (Runs(), Runs(), Runs())
        let s = landStore(origin: origin, facts: facts, find: find)
        s.point(project: "/tmp", worktree: nil, label: "cad-milestone-p3")
        await s.reload(origin: true)?.value
        let first = s.land?.originTag
        await s.reload()?.value
        #expect(first == .absent)
        #expect(s.land?.originTag == first)
    }

    @Test func theSentReasonSurvivesANewStoreForTheSameProject() throws {
        let p = try folder()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let reasons = MilestoneSentReasons()
        let first = MilestoneScreenStore(run: { _ in .success(Self.pass) }, reasons: reasons)
        first.point(project: p)
        first.sent(reason: "need   more\ntime")
        let second = MilestoneScreenStore(run: { _ in .success(Self.pass) }, reasons: reasons)
        second.point(project: p)
        #expect(second.sentReason == "need more time")
        let other = MilestoneScreenStore(run: { _ in .success(Self.pass) }, reasons: reasons)
        other.point(project: "/tmp")
        #expect(other.sentReason == nil)
    }

    @Test func aWorktreeCaptureChangeReloadsTheScreen() async throws {
        let p = try folder()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let wt = p + "/.claude/worktrees/w"
        try FileManager.default.createDirectory(atPath: wt + "/.planning", withIntermediateDirectories: true)
        let (origin, facts, find) = (Runs(), Runs(), Runs())
        let s = landStore(origin: origin, facts: facts, find: find)
        s.point(project: p, worktree: wt, label: "cad-milestone-p1")
        s.sent(reason: "need more time")
        await s.reload()?.value
        #expect(s.land?.captured == [])
        try await Task.sleep(for: .milliseconds(800))
        try "## Notes\n- need more time\n".write(toFile: wt + "/.planning/CAPTURE.md", atomically: true, encoding: .utf8)
        for _ in 0..<500 where s.land?.captured.isEmpty != false { try await Task.sleep(for: .milliseconds(10)) }
        #expect(s.land?.captured == ["- need more time"])
    }

    @Test func theMilestoneScreenKeepsNoAnsweredQuestionLine() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Helm/MilestoneScreenView.swift").path
        #expect(!(try String(contentsOfFile: path, encoding: .utf8)).contains("answered(for"))
    }

    @Test func staleGenerationIsDropped() {
        let s = store(Runs())
        s.point(project: nil)
        let old = s.currentGeneration
        s.reload()
        s.finish(.success(Self.pass), generation: old)
        #expect(s.result == nil)
    }

    @Test func equalResultDoesNotRepublish() {
        let s = store(Runs())
        var changes = 0
        let cancel = s.objectWillChange.sink { changes += 1 }
        let g = s.currentGeneration
        s.finish(.success(Self.pass), generation: g)
        s.finish(.success(Self.pass), generation: g)
        #expect(changes == 1)
        cancel.cancel()
    }
}
