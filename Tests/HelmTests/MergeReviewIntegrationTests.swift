import Foundation
import Testing
@testable import Helm

/// Runs the real `merge-review.sh` against a throwaway git repo. This settles the point CONTEXT flags as
/// "likely to work": `--merge` with `y` on stdin. The real `--kill` stops at once on a fixture without a
/// `sessions` table, so it is not called here (the stub test and the human-verify cover it).
private enum IntegrationGate {
    static let git = "/usr/bin/git"

    static var enabled: Bool {
        guard FileManager.default.isExecutableFile(atPath: MergeReview.script) else { return false }
        let result = ProcessRunner.run(git, ["--version"], environment: TmuxRunner.environment(), timeout: 5)
        // "git version 2.54.0 (Apple Git-157)"
        let parts = result.stdout.split(separator: " ").dropFirst(2).first?.split(separator: ".").compactMap { Int($0) } ?? []
        guard parts.count >= 2 else { return false }
        return parts[0] > 2 || (parts[0] == 2 && parts[1] >= 38)
    }
}

@Suite(.serialized, .enabled(if: IntegrationGate.enabled)) struct MergeReviewIntegrationTests {
    private let environment = TmuxRunner.environment()

    @discardableResult
    private func git(_ args: [String], in folder: String) -> ProcessResult {
        let result = ProcessRunner.run(
            IntegrationGate.git, args, environment: environment, workingFolder: folder, mergeStderr: true, timeout: 30)
        #expect(result.status == 0, "git \(args.joined(separator: " ")): \(result.stdout)")
        return result
    }

    private func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A repo on `main` with 1 commit and 2 worktrees, `alpha` (adds `b.txt`) and `beta` (adds `c.txt`), each on
    /// `session/<label>` with 1 extra commit. The folder name is unique, so the script's base session name
    /// matches no live tmux session.
    private func fixture() throws -> String {
        let made = NSTemporaryDirectory() + "mr-fixture-" + String(UUID().uuidString.prefix(8)).lowercased()
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        let repo = realpath(made, nil).map { ptr in defer { free(ptr) }; return String(cString: ptr) } ?? made
        git(["init", "-q", "-b", "main"], in: repo)
        git(["config", "user.name", "Fixture"], in: repo)
        git(["config", "user.email", "fixture@example.invalid"], in: repo)
        git(["config", "commit.gpgsign", "false"], in: repo)
        try write("a\n", to: repo + "/a.txt")
        git(["add", "a.txt"], in: repo)
        git(["commit", "-q", "-m", "base"], in: repo)
        try FileManager.default.createDirectory(atPath: repo + "/.claude/worktrees", withIntermediateDirectories: true)
        for (label, file) in [("alpha", "b.txt"), ("beta", "c.txt")] {
            let tree = repo + "/.claude/worktrees/" + label
            git(["worktree", "add", "-q", "-b", "session/" + label, tree], in: repo)
            try write(label + "\n", to: tree + "/" + file)
            git(["add", file], in: tree)
            git(["commit", "-q", "-m", "\(label) work"], in: tree)
        }
        return repo
    }

    private func branches(_ repo: String) -> String {
        git(["branch", "--list"], in: repo).stdout
    }

    @Test func previewListsTheFileAndTheCommitAndChangesNothing() throws {
        let repo = try fixture()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let run = MergeReview.preview(label: "alpha", folder: repo, environment: environment)
        #expect(run.failure == nil)
        #expect(run.output.contains("b.txt"), "\(run.output)")
        #expect(run.output.contains("alpha work"), "\(run.output)")
        #expect(branches(repo).contains("session/alpha"))
        #expect(!FileManager.default.fileExists(atPath: repo + "/b.txt"))
    }

    @Test func mergeWithYOnStdinMergesAndPrintsTheMarker() throws {
        let repo = try fixture()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let run = MergeReview.merge(label: "alpha", folder: repo, environment: environment)
        #expect(run.failure == nil)
        #expect(run.status == 0, "\(run.output)")
        #expect(MergeReview.classifyMerge(label: "alpha", status: run.status, output: run.output) == .merged, "\(run.output)")
        #expect(!branches(repo).contains("session/alpha"))
        #expect(FileManager.default.fileExists(atPath: repo + "/b.txt"))
    }

    @Test func teardownOfAnUnmergedBranchIsRefusedAndKeepsTheBranch() throws {
        let repo = try fixture()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let run = MergeReview.teardown(label: "beta", folder: repo, environment: environment)
        #expect(run.failure == nil)
        #expect(run.status == 1, "\(run.output)")
        #expect(MergeReview.classifyTeardown(status: run.status, output: run.output) == .notMerged, "\(run.output)")
        #expect(branches(repo).contains("session/beta"))
    }
}
