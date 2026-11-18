import Foundation

/// Runs G3 for one worker: `uat status` in the verify worktree plus a committed check for its UAT.md. Blocking, so
/// callers run it off the main actor. It reads only: `uat status` and `git ls-files` / `git status`. `status` and `git`
/// are injectable so a test sees every run.
struct UATGateCheck {
    var status: (_ folder: String, _ phase: String) -> UATStatus.Outcome = { folder, phase in
        switch CadenceLocator.locate() {
        case .success(let scripts): return UATStatus.run(scripts, folder: folder, phase: phase)
        case .failure(let failure): return .unreadable(failure.reason)
        }
    }
    var git: (_ args: [String]) -> ProcessResult = { FolderCheck.runGit($0) }

    func run(project: String, row: WorkerRow) -> UATGate.Verdict {
        guard let phase = UATGate.phase(ofLabel: row.agentId) else { return .notGated }
        guard UATStatus.isValidPhase(phase),
              let worktree = UATScreenLoader.insideWorktree(row.worktreePath, project: project)
        else { return .blocked("worker worktree is gone") }
        let relative = ".planning/phases/\(phase)/UAT.md"
        let file = worktree + "/" + relative
        guard FileManager.default.fileExists(atPath: file) else { return .blocked("UAT not started: no UAT.md in the worktree") }
        guard URL(fileURLWithPath: file).resolvingSymlinksInPath().path.hasPrefix(worktree + "/") else {
            return .blocked("UAT.md leaves the worktree")
        }
        let outcome = status(worktree, phase)
        return UATGate.verdict(match: phase, status: outcome, committed: committed(worktree: worktree, relative: relative))
    }

    private func committed(worktree: String, relative: String) -> UATGate.Committed {
        let tracked = git(["-C", worktree, "ls-files", "--error-unmatch", "--", relative])
        if let why = Self.failure(tracked) { return .error(why) }
        // `--error-unmatch` exits 1 for a path git does not track; any other non-zero result is an error.
        if tracked.status == 1 { return .notCommitted }
        guard tracked.status == 0 else { return .error("git ls-files exited \(tracked.status)") }
        let dirty = git(["--no-optional-locks", "-C", worktree, "status", "--porcelain", "--untracked-files=all", "--", relative])
        if let why = Self.failure(dirty) { return .error(why) }
        guard dirty.status == 0 else { return .error("git status exited \(dirty.status)") }
        return dirty.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .committed : .notCommitted
    }

    private static func failure(_ result: ProcessResult) -> String? {
        if let startError = result.startError { return startError }
        if result.timedOut { return "git timed out" }
        return nil
    }
}
