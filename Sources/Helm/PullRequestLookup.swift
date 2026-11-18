import Foundation

/// What a lookup found. A failure is its own case so it can never read as "no pull request".
enum PullRequestLookupResult: Equatable {
    case noPullRequest
    case found(PullRequest)
    /// The first line of what went wrong.
    case failed(String)
}

/// D-15: finds the pull request of one worker with `gh`. Every call blocks, so callers run it off the main actor.
enum PullRequestLookup {
    static let fields = "number,url,state,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,files,changedFiles,headRefOid,title"
    static let timeout: TimeInterval = 20

    static func ghPath() -> String? {
        OrchestratorPaths.searchPath.split(separator: ":")
            .map { "\($0)/gh" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `worktree` is the row's `worktree_path`; without one the orchestrator's default place is used. `gh` and
    /// `runGit` are parameters for tests.
    static func find(
        folder: String, label: String, worktree: String?,
        gh: String? = ghPath(),
        runGit: ([String]) -> ProcessResult = { FolderCheck.runGit($0) }
    ) -> PullRequestLookupResult {
        guard MergeReview.isValidLabel(label) else { return .failed("invalid worker label") }

        // A project with no remote has no pull request, and `gh` exits 1 there ("no git remotes found").
        let remotes = runGit(["-C", folder, "remote"])
        if let problem = problem(remotes, tool: "git remote") { return .failed(problem) }
        if remotes.stdout.allSatisfy(\.isWhitespace) { return .noPullRequest }

        guard let gh else { return .failed("gh not found in \(OrchestratorPaths.searchPath)") }
        var lists: [[PullRequest]] = []
        for branch in branches(folder: folder, label: label, worktree: worktree, runGit: runGit) {
            let result = ProcessRunner.run(
                gh, ["pr", "list", "--head", branch, "--state", "all", "--json", fields],
                environment: TmuxRunner.environment(), workingFolder: folder, timeout: timeout)
            if let problem = problem(result, tool: "gh") { return .failed(problem) }
            do {
                lists.append(try PullRequest.decode(result.stdout))
            } catch {
                return .failed("gh printed text the app cannot read")
            }
        }
        return PullRequest.choose(from: lists).map(PullRequestLookupResult.found) ?? .noPullRequest
    }

    /// `session/<label>` first, then the worktree's current branch when it differs. A worktree that git cannot read adds nothing.
    private static func branches(
        folder: String, label: String, worktree: String?, runGit: ([String]) -> ProcessResult
    ) -> [String] {
        let session = "session/\(label)"
        let path = worktree ?? folder + "/.claude/worktrees/" + label
        let head = runGit(["-C", path, "symbolic-ref", "--short", "HEAD"])
        let current = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.status == 0, !head.timedOut, !head.failedToStart,
              !current.isEmpty, !current.hasPrefix("-"), current != session else { return [session] }
        return [session, current]
    }

    /// Nil for a clean run, else the first line of the reason.
    private static func problem(_ result: ProcessResult, tool: String) -> String? {
        if let startError = result.startError { return startError }
        if result.timedOut { return "\(tool) timed out" }
        if result.status == 0 { return nil }
        let first = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return first.flatMap { $0.isEmpty ? nil : $0 } ?? "\(tool) exited \(result.status)"
    }
}
