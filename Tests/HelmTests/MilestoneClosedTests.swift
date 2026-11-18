import Foundation
import Testing
@testable import Helm

struct MilestoneClosedTests {
    private func status(cycle: String?) -> CadenceStatus {
        CadenceStatus(current: nil, total: 3, cycle: cycle, phases: [], cursorNext: nil)
    }

    @Test func cycleNoneIsClosed() {
        let closed = MilestoneClosed(status: { _ in .success(status(cycle: "none")) })
        #expect(closed.read(project: "/p", worktree: nil) == .closed)
        #expect(closed.read(project: "/p", worktree: nil).isClosed)
    }

    @Test func anOpenCycleIsNotClosed() {
        let open = MilestoneClosed(status: { _ in .success(status(cycle: nil)) })
        #expect(open.read(project: "/p", worktree: nil) == .open)
        #expect(!open.read(project: "/p", worktree: nil).isClosed)
    }

    @Test func aFailureIsNotClosedWithItsReason() {
        let failed = MilestoneClosed(status: { _ in .failure(.init(reason: "node missing")) })
        #expect(failed.read(project: "/p", worktree: nil) == .unreadable("node missing"))
        #expect(!failed.read(project: "/p", worktree: nil).isClosed)
    }

    @Test func theWorktreeIsAskedWhenItIsInsideTheWorktreesFolder() throws {
        let raw = NSTemporaryDirectory() + "milestone-closed-" + UUID().uuidString.prefix(8).lowercased()
        let wt = raw + "/.claude/worktrees/cad-milestone-p3"
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: raw) }
        let project = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        let seen = Box()
        let closed = MilestoneClosed(status: { folder in seen.set(folder); return .success(status(cycle: "none")) })
        _ = closed.read(project: project, worktree: wt)
        #expect(seen.value.hasSuffix("/.claude/worktrees/cad-milestone-p3"))
        _ = closed.read(project: project, worktree: "/elsewhere")
        #expect(seen.value == project)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }
}
