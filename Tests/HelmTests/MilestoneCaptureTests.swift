import Foundation
import Testing
@testable import Helm

struct MilestoneCaptureTests {
    private func folder() throws -> String {
        let raw = NSTemporaryDirectory() + "milestone-capture-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: raw + "/.claude/worktrees/cad-milestone-p3/.planning", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: raw + "/.planning", withIntermediateDirectories: true)
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    private func put(_ text: String, _ path: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }

    private func wt(_ p: String) -> String { p + "/.claude/worktrees/cad-milestone-p3" }

    @Test func aWorktreeCopyWinsAndTheProjectCopyIsTheFallback() throws {
        let p = try folder()
        defer { try? FileManager.default.removeItem(atPath: p) }
        try put("## Notes\n- ship it now\n", p + "/.planning/CAPTURE.md")
        #expect(MilestoneCapture.read(project: p, worktree: nil, reason: "ship it") == ["- ship it now"])
        try put("## Notes\n- ship it from worktree\n", wt(p) + "/.planning/CAPTURE.md")
        #expect(MilestoneCapture.read(project: p, worktree: wt(p), reason: "ship it") == ["- ship it from worktree"])
    }

    @Test func aSymlinkOutOfTheWorktreeIsNotRead() throws {
        let p = try folder()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let outside = p + "/outside.md"
        try put("## Notes\n- ship it\n", outside)
        try FileManager.default.createSymbolicLink(atPath: wt(p) + "/.planning/CAPTURE.md", withDestinationPath: outside)
        #expect(MilestoneCapture.read(project: p, worktree: wt(p), reason: "ship it").isEmpty)
    }

    @Test func onlyColumnZeroBulletsInWalkedSectionsMatch() throws {
        let p = try folder()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let text = """
        ## Todos
        - [x] done: ship it
        - (phase 3) tagged ship it
        - unrelated
        * star ship it
          - indented ship it
        | table | ship it |
        prose ship it
        ## Debt markers
        - ship it in debt
        ## Seeds
        - Ship   IT
        with more
        """
        try put(text, p + "/.planning/CAPTURE.md")
        #expect(MilestoneCapture.read(project: p, worktree: nil, reason: "ship it") ==
                ["- [x] done: ship it", "- (phase 3) tagged ship it", "- Ship IT"])
    }

    @Test func aReasonWithANewlineMatchesItsFlattenedBullet() throws {
        let p = try folder()
        defer { try? FileManager.default.removeItem(atPath: p) }
        try put("## Notes\n- override: two words here\n", p + "/.planning/CAPTURE.md")
        #expect(MilestoneCapture.read(project: p, worktree: nil, reason: "two\nwords  here") == ["- override: two words here"])
        #expect(MilestoneCapture.read(project: p, worktree: nil, reason: "absent text").isEmpty)
        #expect(MilestoneCapture.read(project: p, worktree: nil, reason: nil).isEmpty)
    }

    @Test func theReadLeavesModificationTimesAlone() throws {
        let p = try folder()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let file = p + "/.planning/CAPTURE.md"
        try put("## Notes\n- ship it\n", file)
        func mtime() -> Date? { try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date }
        let before = mtime()
        _ = MilestoneCapture.read(project: p, worktree: nil, reason: "ship it")
        #expect(mtime() == before)
    }
}
