import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct ExecuteCommitsTests {
    private func env() throws -> [String: String] {
        let home = NSTemporaryDirectory() + "exec-commits-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try "[user]\n\tname = Test\n\temail = test@example.com\n".write(toFile: home + "/.gitconfig", atomically: true, encoding: .utf8)
        return ["PATH": OrchestratorPaths.searchPath, "HOME": home, "LANG": "en_US.UTF-8"]
    }

    /// A temp repository with 2 commits; returns the folder and the 2 full hashes.
    private func repo() throws -> (String, [String]) {
        let env = try env()
        let dir = NSTemporaryDirectory() + "exec-commits-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = FolderCheck.runGit(["-C", dir, "init"], environment: env)
        var hashes: [String] = []
        for n in 1...2 {
            _ = FolderCheck.runGit(["-C", dir, "commit", "--allow-empty", "-m", "c\(n)"], environment: env)
            hashes.append(FolderCheck.runGit(["-C", dir, "rev-parse", "HEAD"], environment: env)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (dir, hashes)
    }

    @Test func fullAndShortHashesResolveAndUnknownIsMissing() throws {
        let (dir, h) = try repo()
        let out = ExecuteCommits.check(root: dir, commits: [h[0], String(h[1].prefix(7)), "deadbee"])
        #expect(out == .checked([.resolved, .resolved, .missing]))
    }

    @Test func textsThatAreNotHashesNeverReachGit() throws {
        let marker = "/tmp/exec-ac-\(UUID().uuidString)"
        var runs = 0
        let texts = ["-", "", "HEAD", "abc1234; touch \(marker)", "abc123", String(repeating: "a", count: 41)]
        let out = ExecuteCommits.check(root: "/", commits: texts) { _, _ in runs += 1; return ProcessResult(status: 0, stdout: "", stderr: "") }
        #expect(out == .checked(Array(repeating: .notHash, count: texts.count)))
        #expect(runs == 0 && !FileManager.default.fileExists(atPath: marker))
    }

    @Test func oneGitRunServesAllHashesAndKeepsPositions() throws {
        let (dir, h) = try repo()
        var runs = 0
        var inputs: [String] = []
        let out = ExecuteCommits.check(root: dir, commits: ["-", h[0], "HEAD", "deadbee"]) { root, input in
            runs += 1; inputs.append(input)
            return ExecuteCommits.runGit(root: root, input: input)
        }
        #expect(out == .checked([.notHash, .resolved, .notHash, .missing]))
        #expect(runs == 1 && inputs == ["\(h[0])^{commit}\ndeadbee^{commit}\n"])
    }

    @Test func aFolderThatIsNotARepositoryIsUncheckedWithAReason() throws {
        let dir = NSTemporaryDirectory() + "exec-commits-plain-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard case .unchecked(let reason) = ExecuteCommits.check(root: dir, commits: ["abc1234"]) else {
            Issue.record("expected unchecked"); return
        }
        #expect(!reason.isEmpty)
    }

    @Test func aGitThatCannotStartOrTimesOutIsUnchecked() {
        let start = ExecuteCommits.check(root: "/", commits: ["abc1234"]) { _, _ in
            ProcessResult(status: -1, stdout: "", stderr: "", startError: "no git")
        }
        #expect(start == .unchecked("no git"))
        let slow = ExecuteCommits.check(root: "/", commits: ["abc1234"]) { _, _ in
            ProcessResult(status: 0, stdout: "", stderr: "", timedOut: true)
        }
        #expect(slow == .unchecked("git timed out"))
    }
}
