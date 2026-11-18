import Foundation

enum FolderKind: Equatable {
    case repo
    case nonRepo
    /// The folder sits below another repo's top level.
    case insideRepo(top: String)
    /// Git is missing, or refuses to read the folder (dubious ownership). Carries git's own text.
    case unreadable(String)
}

struct FolderCheckFailure: Error, LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// D-09 / PROJ-03: what the chosen folder is, and the `git init` offer for a plain folder.
/// Git runs with an explicit PATH, HOME and LANG, so a `GIT_DIR` in the app's environment cannot redirect it.
enum FolderCheck {
    static func gitPath() -> String? {
        OrchestratorPaths.searchPath.split(separator: ":")
            .map { "\($0)/git" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Git prints the real path, and the folder picker may not (the launcher compares with `pwd -P` too).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func runGit(_ args: [String], environment: [String: String] = TmuxRunner.environment()) -> ProcessResult {
        guard let git = gitPath() else {
            return ProcessResult(status: -1, stdout: "", stderr: "", startError: "git not found in \(OrchestratorPaths.searchPath)")
        }
        return ProcessRunner.run(git, args, environment: environment, timeout: 10)
    }

    private static func text(_ result: ProcessResult) -> String {
        if let startError = result.startError { return startError }
        if result.timedOut { return "git timed out" }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return !stderr.isEmpty ? stderr : !stdout.isEmpty ? stdout : "git exited \(result.status)"
    }

    static func classify(_ folder: String, environment: [String: String] = TmuxRunner.environment()) -> FolderKind {
        let result = runGit(["-C", folder, "rev-parse", "--show-toplevel"], environment: environment)
        if result.status == 0, !result.timedOut {
            let top = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return realPath(top) == realPath(folder) ? .repo : .insideRepo(top: top)
        }
        if result.status == 128, result.stderr.contains("not a git repository") { return .nonRepo }
        return .unreadable(text(result))
    }

    /// `git init`, then an empty first commit. If a step fails and `.git` did not exist before, the `.git`
    /// that the init created goes again, so the folder is as it was. A `.git` that existed is never removed.
    static func initRepo(_ folder: String, environment: [String: String] = TmuxRunner.environment()) throws {
        let gitFolder = folder + "/.git"
        let existed = FileManager.default.fileExists(atPath: gitFolder)
        for args in [["init"], ["commit", "--allow-empty", "-m", "Initial commit"]] {
            let result = runGit(["-C", folder] + args, environment: environment)
            if result.status != 0 || result.timedOut || result.failedToStart {
                if !existed { try? FileManager.default.removeItem(atPath: gitFolder) }
                throw FolderCheckFailure(reason: text(result))
            }
        }
    }
}
