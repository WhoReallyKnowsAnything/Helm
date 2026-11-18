import Foundation
import Testing
@testable import Helm

@Suite struct EditorAccessTests {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gui-test-access-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func row(_ id: String, _ status: String, _ worktree: String?) -> WorkerRow {
        WorkerRow(agentId: id, status: status, taskTitle: nil, lastEvent: nil, worktreePath: worktree)
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func projectFileIsEditable() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/a.swift")
        try touch(file)
        #expect(EditorAccess.resolve(file, project: root, rows: []) == .editable)
    }

    @Test func planningFileIsReadOnly() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".planning/phases/4/PLAN.md")
        try touch(file)
        let access = EditorAccess.resolve(file, project: root, rows: [])
        #expect(access.reason?.contains("Cadence owns") == true)
    }

    @Test func liveWorktreeFileIsReadOnlyAndNamesTheWorker() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent(".claude/worktrees/w1")
        let file = tree.appendingPathComponent("a.swift")
        try touch(file)
        for status in ["running", "blocked", "done"] {
            let access = EditorAccess.resolve(file, project: root, rows: [row("w1", status, tree.path)])
            #expect(access.reason?.contains("w1") == true)
        }
    }

    @Test func mergedOrDeadWorktreeFileIsEditable() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent(".claude/worktrees/w1")
        let file = tree.appendingPathComponent("a.swift")
        try touch(file)
        for status in ["merged", "dead"] {
            #expect(EditorAccess.resolve(file, project: root, rows: [row("w1", status, tree.path)]) == .editable)
        }
    }

    @Test func planningFileInMergedWorktreeIsReadOnly() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent(".claude/worktrees/w1")
        let file = tree.appendingPathComponent(".planning/STATE.md")
        try touch(file)
        let access = EditorAccess.resolve(file, project: root, rows: [row("w1", "merged", tree.path)])
        #expect(!access.isEditable)
    }

    @Test func siblingFolderWithSamePrefixIsNotInside() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("proj")
        let evil = root.appendingPathComponent("proj-evil/a.swift")
        try touch(evil)
        #expect(EditorAccess.resolve(evil, project: root.appendingPathComponent("other"), rows: [row("w1", "running", tree.path)]) == .editable)
        #expect(EditorAccess.owner(of: evil, rows: [row("w1", "running", tree.path)]) == nil)
    }

    @Test func symlinkIntoLiveWorktreeIsReadOnly() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent(".claude/worktrees/w1")
        try touch(tree.appendingPathComponent("a.swift"))
        let link = root.appendingPathComponent("link.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.appendingPathComponent("a.swift"))
        let access = EditorAccess.resolve(link, project: root, rows: [row("w1", "running", tree.path)])
        #expect(!access.isEditable)
    }

    @Test func nilWorktreeRowsAreSkippedAndOwnerIgnoresStatus() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent(".claude/worktrees/w1")
        let file = tree.appendingPathComponent("a.swift")
        try touch(file)
        let rows = [row("none", "running", nil), row("w1", "merged", tree.path)]
        #expect(EditorAccess.owner(of: file, rows: rows)?.agentId == "w1")
        #expect(EditorAccess.owner(of: root.appendingPathComponent("b.swift"), rows: rows) == nil)
    }
}
