import Foundation
import Testing
@testable import OrchestratorGUI

@Suite(.serialized) struct MilestoneLandFactsTests {
    private func git(_ args: [String], in dir: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    /// A project with one commit and a linked worktree two commits ahead.
    private func repo() throws -> (project: String, worktree: String) {
        let raw = NSTemporaryDirectory() + "milestone-facts-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let project = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        try git(["init", "-q", "-b", "main"], in: project)
        try git(["commit", "-q", "--allow-empty", "-m", "base"], in: project)
        let worktree = project + "/.claude/worktrees/cad-milestone-p3"
        try FileManager.default.createDirectory(atPath: project + "/.claude/worktrees", withIntermediateDirectories: true)
        try git(["worktree", "add", "-q", "-b", "session/cad-milestone-p3", worktree], in: project)
        try git(["commit", "-q", "--allow-empty", "-m", "one"], in: worktree)
        try git(["commit", "-q", "--allow-empty", "-m", "two"], in: worktree)
        return (project, URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path)
    }

    @Test func twoAheadAndCleanGivesBranchTwoClean() throws {
        let r = try repo()
        defer { try? FileManager.default.removeItem(atPath: r.project) }
        #expect(MilestoneLandFacts.read(project: r.project, worktree: r.worktree)
                == .facts(branch: "session/cad-milestone-p3", ahead: 2, dirty: false))
    }

    @Test func anUntrackedFileIsDirty() throws {
        let r = try repo()
        defer { try? FileManager.default.removeItem(atPath: r.project) }
        FileManager.default.createFile(atPath: r.worktree + "/new.txt", contents: Data("x".utf8))
        #expect(MilestoneLandFacts.read(project: r.project, worktree: r.worktree)
                == .facts(branch: "session/cad-milestone-p3", ahead: 2, dirty: true))
    }

    @Test func aPathOutsideTheWorktreesFolderIsNoWorktree() throws {
        let r = try repo()
        defer { try? FileManager.default.removeItem(atPath: r.project) }
        #expect(MilestoneLandFacts.read(project: r.project, worktree: r.project) == .noWorktree)
        #expect(MilestoneLandFacts.read(project: r.project, worktree: nil) == .noWorktree)
    }

    @Test func aFailingRunnerGivesItsFirstStderrLine() throws {
        let r = try repo()
        defer { try? FileManager.default.removeItem(atPath: r.project) }
        let failing: MilestoneLandFacts.RunGit = { _ in
            ProcessResult(status: 128, stdout: "", stderr: "fatal: not a git repository\nmore\n")
        }
        #expect(MilestoneLandFacts.read(project: r.project, worktree: r.worktree, runGit: failing)
                == .failed("fatal: not a git repository"))
    }
}
