import Foundation

/// Whether the cycle is closed in the milestone worker's copy. The close happens in the worker's worktree, so the project
/// folder keeps showing an open cycle until the merge. Read-only; `status` is injectable as `UATScreenLoader.status` is.
struct MilestoneClosed {
    enum Answer: Equatable {
        case closed
        case open
        /// The status failed; counts as not closed.
        case unreadable(String)

        var isClosed: Bool { self == .closed }
    }

    var status: (_ folder: String) -> Result<CadenceStatus, CadenceLocator.Failure> = { folder in
        switch CadenceLocator.locate() {
        case .success(let scripts): return CadenceStatus.run(scripts, project: folder)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// The worktree's status when it sits inside `<project>/.claude/worktrees/`, else the project folder's.
    func read(project: String, worktree: String?) -> Answer {
        let folder = UATScreenLoader.insideWorktree(worktree, project: project) ?? project
        switch status(folder) {
        case .success(let value): return value.cycle == "none" ? .closed : .open
        case .failure(let failure): return .unreadable(failure.reason)
        }
    }
}
