import Foundation

/// What `git` says about the milestone worker's worktree. Read-only; every call blocks, so callers run it off the main actor.
enum MilestoneLandFacts: Equatable {
    case noWorktree
    case facts(branch: String, ahead: Int, dirty: Bool)
    /// The first stderr line of the git call that failed.
    case failed(String)

    typealias RunGit = ([String]) -> ProcessResult

    /// Ahead is the commits on the worktree branch that the project folder's checked-out branch does not hold.
    static func read(project: String, worktree: String?, runGit: RunGit = { FolderCheck.runGit($0) }) -> MilestoneLandFacts {
        guard let wt = UATScreenLoader.insideWorktree(worktree, project: project) else { return .noWorktree }
        let branch = runGit(["-C", wt, "symbolic-ref", "--short", "HEAD"])
        if let why = problem(branch, tool: "git symbolic-ref") { return .failed(why) }
        let base = runGit(["-C", project, "symbolic-ref", "--short", "HEAD"])
        if let why = problem(base, tool: "git symbolic-ref") { return .failed(why) }
        let name = branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = runGit(["-C", wt, "rev-list", "--count", "\(baseName)..\(name)"])
        if let why = problem(count, tool: "git rev-list") { return .failed(why) }
        guard let ahead = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failed("git rev-list printed text the app cannot read")
        }
        let status = runGit(["-C", wt, "status", "--porcelain"])
        if let why = problem(status, tool: "git status") { return .failed(why) }
        return .facts(branch: name, ahead: ahead, dirty: !status.stdout.allSatisfy(\.isWhitespace))
    }

    /// Nil for a clean run, else the first line of the reason (the same shape `PullRequestLookup` gives).
    static func problem(_ result: ProcessResult, tool: String) -> String? {
        if let startError = result.startError { return startError }
        if result.timedOut { return "\(tool) timed out" }
        if result.status == 0 { return nil }
        let first = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return first.flatMap { $0.isEmpty ? nil : $0 } ?? "\(tool) exited \(result.status)"
    }
}
