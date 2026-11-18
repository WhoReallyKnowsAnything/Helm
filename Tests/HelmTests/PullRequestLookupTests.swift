import Foundation
import Testing
@testable import Helm

struct PullRequestLookupTests {
    private let fields = "number,url,state,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,files,changedFiles,headRefOid,title"

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "gui-test-pr-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real repository on `branch`. `remote` adds an origin, so `git remote` lists one name.
    private func repo(branch: String = "main", remote: Bool) throws -> String {
        let dir = try tempDir()
        let init_ = FolderCheck.runGit(["init", "-q", "-b", branch, dir])
        #expect(init_.status == 0)
        if remote { #expect(FolderCheck.runGit(["-C", dir, "remote", "add", "origin", "https://example.invalid/o/r.git"]).status == 0) }
        return dir
    }

    /// A stub `gh`: it appends its working folder and argv to `mark`, then runs `body` (shell text). `$4` is the branch.
    private func stub(_ body: String) throws -> (path: String, mark: String) {
        let dir = try tempDir()
        let path = dir + "/gh", mark = dir + "/mark"
        try "#!/bin/bash\nMARK='\(mark)'\n{ echo \"CWD=$(pwd -P)\"; echo \"ARGV=$*\"; } >> \"$MARK\"\n\(body)\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, mark)
    }

    private func calls(_ mark: String) -> [String] {
        ((try? String(contentsOfFile: mark, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func json(_ number: Int, _ state: String) -> String { #"[{"number":\#(number),"state":"\#(state)","title":"t"}]"# }

    private func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test func ghRunsInTheProjectFolderWithTheExactArguments() throws {
        let folder = try repo(remote: true)
        let gh = try stub("echo '[]'")
        let result = PullRequestLookup.find(folder: folder, label: "alpha", worktree: nil, gh: gh.path)
        #expect(result == .noPullRequest)
        #expect(calls(gh.mark) == ["CWD=\(realPath(folder))", "ARGV=pr list --head session/alpha --state all --json \(fields)"])
    }

    @Test func aDifferentWorktreeBranchRunsGhTwice() throws {
        let folder = try repo(remote: true), worktree = try repo(branch: "feature-x", remote: false)
        let gh = try stub("echo '[]'")
        _ = PullRequestLookup.find(folder: folder, label: "alpha", worktree: worktree, gh: gh.path)
        let heads = calls(gh.mark).filter { $0.hasPrefix("ARGV=") }.map { $0.split(separator: " ")[3] }
        #expect(heads == ["session/alpha", "feature-x"])
    }

    @Test func theSameWorktreeBranchRunsGhOnce() throws {
        let folder = try repo(remote: true), worktree = try repo(branch: "session/alpha", remote: false)
        let gh = try stub("echo '[]'")
        _ = PullRequestLookup.find(folder: folder, label: "alpha", worktree: worktree, gh: gh.path)
        #expect(calls(gh.mark).filter { $0.hasPrefix("ARGV=") }.count == 1)
    }

    @Test func anUnreadableWorktreeAddsNoSecondRun() throws {
        let folder = try repo(remote: true)
        let gh = try stub("echo '[]'")
        _ = PullRequestLookup.find(folder: folder, label: "alpha", worktree: folder + "/missing", gh: gh.path)
        #expect(calls(gh.mark).filter { $0.hasPrefix("ARGV=") }.count == 1)
    }

    @Test func anOpenResultBeatsAMergedOne() throws {
        let folder = try repo(remote: true), worktree = try repo(branch: "feature-x", remote: false)
        let gh = try stub("""
            case "$4" in
              session/alpha) echo '\(json(9, "MERGED"))' ;;
              *) echo '\(json(3, "OPEN"))' ;;
            esac
            """)
        guard case .found(let pr) = PullRequestLookup.find(folder: folder, label: "alpha", worktree: worktree, gh: gh.path)
        else { Issue.record("expected a pull request"); return }
        #expect(pr.number == 3)
    }

    @Test func aFailingGhIsAFailureWithTheFirstStderrLine() throws {
        let folder = try repo(remote: true)
        let gh = try stub("echo 'gh: not logged in' >&2; echo 'second line' >&2; exit 1")
        #expect(PullRequestLookup.find(folder: folder, label: "alpha", worktree: nil, gh: gh.path) == .failed("gh: not logged in"))
    }

    @Test func aFailureWithNoStderrNamesTheExitCode() throws {
        let folder = try repo(remote: true)
        let gh = try stub("exit 4")
        #expect(PullRequestLookup.find(folder: folder, label: "alpha", worktree: nil, gh: gh.path) == .failed("gh exited 4"))
    }

    @Test func textThatIsNotJsonIsAFailureNotNoPullRequest() throws {
        let folder = try repo(remote: true)
        let gh = try stub("echo 'hello'")
        guard case .failed = PullRequestLookup.find(folder: folder, label: "alpha", worktree: nil, gh: gh.path)
        else { Issue.record("expected a failure"); return }
    }

    @Test func aMissingGhIsAFailure() throws {
        let folder = try repo(remote: true)
        guard case .failed = PullRequestLookup.find(folder: folder, label: "alpha", worktree: nil, gh: nil),
              case .failed = PullRequestLookup.find(folder: folder, label: "alpha", worktree: nil, gh: folder + "/no-gh")
        else { Issue.record("expected failures"); return }
    }

    @Test func aProjectWithNoRemoteHasNoPullRequestAndGhIsNotCalled() throws {
        let folder = try repo(remote: false)
        let gh = try stub("echo '\(json(1, "OPEN"))'")
        #expect(PullRequestLookup.find(folder: folder, label: "alpha", worktree: nil, gh: gh.path) == .noPullRequest)
        #expect(!FileManager.default.fileExists(atPath: gh.mark))
    }

    @Test func aFolderGitCannotReadIsAFailure() throws {
        let gh = try stub("echo '[]'")
        guard case .failed = PullRequestLookup.find(folder: try tempDir(), label: "alpha", worktree: nil, gh: gh.path)
        else { Issue.record("expected a failure"); return }
        #expect(!FileManager.default.fileExists(atPath: gh.mark))
    }

    @Test(arguments: ["", "-x", "../x", "a b", "a;b", "a\nb", "a/b"])
    func anInvalidLabelStartsNothing(label: String) throws {
        let folder = try repo(remote: true)
        let gh = try stub("echo '[]'")
        var gitCalls = 0
        let result = PullRequestLookup.find(folder: folder, label: label, worktree: nil, gh: gh.path) { _ in
            gitCalls += 1
            return ProcessResult(status: 0, stdout: "origin\n", stderr: "")
        }
        #expect(result == .failed("invalid worker label"))
        #expect(gitCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: gh.mark))
    }
}
