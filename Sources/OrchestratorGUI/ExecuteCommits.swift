import Foundation

/// Checks the commit cells of a report's task rows against `git` in the folder the report came from (D-08, D-09).
/// Report text is data: only a text of 7 to 40 hex digits and nothing else reaches git, on stdin of one
/// `cat-file --batch-check` child. Read-only.
enum ExecuteCommits {
    enum Check: Equatable { case resolved, missing, notHash }

    enum Outcome: Equatable {
        /// One check per input text, in order.
        case checked([Check])
        /// git could not answer for the whole list; no hash is marked missing then.
        case unchecked(String)
    }

    /// Runs git with the batch input in `root`.
    typealias Run = (_ root: String, _ input: String) -> ProcessResult

    static func check(root: String, commits: [String], run: Run = runGit) -> Outcome {
        let texts = commits.map { $0.trimmingCharacters(in: .whitespaces) }
        let hashes = texts.filter(isHash)
        guard !hashes.isEmpty else { return .checked(texts.map { _ in .notHash }) }
        let result = run(root, hashes.map { "\($0)^{commit}\n" }.joined())
        if let reason = result.startError { return .unchecked(reason) }
        if result.timedOut { return .unchecked("git timed out") }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        guard result.status == 0, lines.count == hashes.count else {
            let why = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unchecked(why.isEmpty ? "git exited \(result.status)" : why)
        }
        // A found commit prints "<sha> commit <size>"; anything else ("missing", "ambiguous") is not one.
        var next = lines.makeIterator()
        return .checked(texts.map { isHash($0) ? (next.next()!.contains(" commit ") ? .resolved : .missing) : .notHash })
    }

    private static func isHash(_ text: String) -> Bool {
        (7...40).contains(text.utf8.count) && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }

    /// The plan's task commits from `git log --format=%h%x09%s` lines (newest first), oldest first, as rows noted "from git".
    /// Executor commits are `<type>(<phase>-<plan>): <subject>`.
    static func liveRows(log: String, phase: String, k: Int) -> [ExecuteReport.Row] {
        let scope = "(\(phase)-\(k)): "
        return log.split(separator: "\n").reversed().compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let open = parts[1].firstIndex(of: "("), open > parts[1].startIndex,
                  parts[1][..<open].allSatisfy(\.isLetter), parts[1][open...].hasPrefix(scope) else { return nil }
            return ExecuteReport.Row(task: String(parts[1][open...].dropFirst(scope.count)), commit: String(parts[0]), note: "from git")
        }
    }

    /// `git log <base>..HEAD` in the worktree, where base is the project's current branch. Empty when git cannot answer.
    static func liveLog(worktree: String, project: String) -> String {
        guard let git = FolderCheck.gitPath() else { return "" }
        let environment = TmuxRunner.environment()
        let head = ProcessRunner.run(git, ["symbolic-ref", "--short", "HEAD"], environment: environment,
                                     workingFolder: project, timeout: 10)
        let base = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.status == 0, !base.isEmpty, !base.hasPrefix("-") else { return "" }
        let log = ProcessRunner.run(git, ["log", "--format=%h%x09%s", "\(base)..HEAD"], environment: environment,
                                    workingFolder: worktree, timeout: 10)
        return log.status == 0 ? log.stdout : ""
    }

    /// The worktree's own git folder (its `.git` file holds `gitdir: <path>`), nil when it is not a linked worktree.
    static func gitDir(ofWorktree worktree: String) -> String? {
        guard let text = try? String(contentsOfFile: worktree + "/.git", encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
        let path = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : worktree + "/" + path
    }

    static func runGit(root: String, input: String) -> ProcessResult {
        guard let git = FolderCheck.gitPath() else {
            return ProcessResult(status: -1, stdout: "", stderr: "", startError: "git not found in \(OrchestratorPaths.searchPath)")
        }
        return ProcessRunner.run(git, ["cat-file", "--batch-check"], environment: TmuxRunner.environment(),
                                 workingFolder: root, input: input, timeout: 10)
    }
}
