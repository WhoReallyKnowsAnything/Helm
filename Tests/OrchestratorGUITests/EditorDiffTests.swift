import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct EditorDiffTests {
    private func git(_ args: [String], in dir: String) -> String {
        let base = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        return ProcessRunner.run("/usr/bin/git", base + args, environment: ["HOME": NSHomeDirectory()],
                                 workingFolder: dir, timeout: 20).stdout
    }

    private func lines(_ blocks: [DiffBlock], _ kind: DiffLine.Kind) -> [String] {
        blocks.flatMap(\.lines).filter { $0.kind == kind }.map(\.text)
    }

    @Test func oneHunkKeepsContextAddedAndRemoved() {
        let text = "diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
        let blocks = EditorDiff.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].lines == [DiffLine(kind: .unchanged, text: "a"), DiffLine(kind: .removed, text: "b"),
                                    DiffLine(kind: .added, text: "B"), DiffLine(kind: .unchanged, text: "c")])
    }

    @Test func twoHunksMakeTwoBlocks() {
        let text = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+A\n@@ -9 +9 @@\n-z\n+Z\n"
        #expect(EditorDiff.parse(text).count == 2)
    }

    @Test func deletedAndAddedLines() {
        #expect(lines(EditorDiff.parse("@@ -1,2 +1 @@\n a\n-gone\n"), .removed) == ["gone"])
        #expect(lines(EditorDiff.parse("@@ -1 +1,2 @@\n a\n+new\n"), .added) == ["new"])
    }

    @Test func noNewlineMarkerIsIgnored() {
        let blocks = EditorDiff.parse("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n")
        #expect(blocks[0].lines.count == 2)
    }

    @Test func aRemovedLineStartingWithDashesIsStillRemoved() {
        #expect(lines(EditorDiff.parse("@@ -1 +1 @@\n--- x\n+++ y\n"), .removed) == ["-- x"])
    }

    @Test func emptyOutputIsNoBlocks() {
        #expect(EditorDiff.parse("") == [])
    }

    @Test func readerMatchesRawGitDiffInARealRepo() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "ed-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try (1...12).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        _ = git(["init", "-q"], in: dir.path)
        _ = git(["add", "a.txt"], in: dir.path)
        _ = git(["commit", "-q", "-m", "init"], in: dir.path)
        // A clean file has no blocks.
        #expect(EditorDiff.read(file) == .blocks([]))
        var edited = (1...12).map { "line \($0)" }
        edited[1] = "changed 2"; edited[5] = "changed 6"; edited[10] = "changed 11"
        try (edited.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let raw = git(["diff", "HEAD", "--no-color", "--", "a.txt"], in: dir.path)
        let rawLines = raw.split(separator: "\n").map(String.init)
        let rawAdded = rawLines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.map { String($0.dropFirst()) }
        let rawRemoved = rawLines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.map { String($0.dropFirst()) }
        guard case .blocks(let blocks) = EditorDiff.read(file) else { Issue.record("expected blocks"); return }
        #expect(Set(lines(blocks, .added)) == Set(rawAdded) && lines(blocks, .added).count == 3)
        #expect(Set(lines(blocks, .removed)) == Set(rawRemoved) && lines(blocks, .removed).count == 3)
    }

    @Test func aFolderThatIsNotARepoFails() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "ed-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        guard case .failed(let reason) = EditorDiff.read(file) else { Issue.record("expected a failure"); return }
        #expect(!reason.isEmpty)
    }
}
