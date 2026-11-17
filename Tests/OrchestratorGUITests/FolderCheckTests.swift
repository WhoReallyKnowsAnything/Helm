import Foundation
import Testing
@testable import OrchestratorGUI

struct FolderCheckTests {
    /// A HOME with a git identity (or none), so the tests do not depend on the developer's global config.
    private func environment(identity: Bool) throws -> [String: String] {
        let home = NSTemporaryDirectory() + "folder-check-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let config = identity
            ? "[user]\n\tname = Test\n\temail = test@example.com\n"
            : "[user]\n\tuseConfigOnly = true\n"
        try config.write(toFile: home + "/.gitconfig", atomically: true, encoding: .utf8)
        return ["PATH": OrchestratorPaths.searchPath, "HOME": home, "LANG": "en_US.UTF-8"]
    }

    private func newFolder() throws -> String {
        let dir = NSTemporaryDirectory() + "folder-check-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func git(_ dir: String, _ args: [String], _ env: [String: String]) -> ProcessResult {
        FolderCheck.runGit(["-C", dir] + args, environment: env)
    }

    @Test func anEmptyFolderIsNotARepo() throws {
        #expect(FolderCheck.classify(try newFolder()) == .nonRepo)
    }

    @Test func aGitInitFolderIsARepo() throws {
        let env = try environment(identity: true)
        let dir = try newFolder()
        _ = git(dir, ["init"], env)
        #expect(FolderCheck.classify(dir, environment: env) == .repo)
    }

    @Test func aSubfolderIsInsideAnotherRepo() throws {
        let env = try environment(identity: true)
        let dir = try newFolder()
        _ = git(dir, ["init"], env)
        let sub = dir + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        #expect(FolderCheck.classify(sub, environment: env) == .insideRepo(top: FolderCheck.realPath(dir)))
    }

    @Test func aSymlinkToARepoTopIsARepo() throws {
        let env = try environment(identity: true)
        let dir = try newFolder()
        _ = git(dir, ["init"], env)
        let link = try newFolder() + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir)
        #expect(FolderCheck.classify(link, environment: env) == .repo)
    }

    @Test func aLinkedWorktreeIsARepo() throws {
        let env = try environment(identity: true)
        let dir = try newFolder()
        try FolderCheck.initRepo(dir, environment: env)
        let worktree = try newFolder() + "-wt"
        let added = git(dir, ["worktree", "add", worktree], env)
        #expect(added.status == 0, "\(added.stderr)")
        #expect(FolderCheck.classify(worktree, environment: env) == .repo)
    }

    @Test func initLeavesOneCommit() throws {
        let env = try environment(identity: true)
        let dir = try newFolder()
        try FolderCheck.initRepo(dir, environment: env)
        #expect(FileManager.default.fileExists(atPath: dir + "/.git"))
        #expect(git(dir, ["rev-list", "--count", "HEAD"], env).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test func aFailedCommitRemovesTheGitFolderTheInitMade() throws {
        let env = try environment(identity: false)
        let dir = try newFolder()
        let failure = #expect(throws: FolderCheckFailure.self) { try FolderCheck.initRepo(dir, environment: env) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).isEmpty)
        #expect(failure?.reason.isEmpty == false)
    }
}
