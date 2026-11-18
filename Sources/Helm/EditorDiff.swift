import Foundation

/// D-06: the saved file's uncommitted change, read from `git diff HEAD` (never from the buffer).
enum EditorDiff {
    enum Outcome: Equatable {
        /// One block per hunk. Empty when the file has no change against HEAD.
        case blocks([DiffBlock])
        case failed(String)
    }

    /// Runs git in the file's own folder, so a file in a worktree uses that worktree's repo. `--no-ext-diff` and
    /// `--no-textconv` keep a repo's configured drivers from running programs.
    static func read(_ file: URL, run: ([String]) -> ProcessResult = { FolderCheck.runGit($0) }) -> Outcome {
        let real = file.standardizedFileURL.resolvingSymlinksInPath()
        let result = run(["-C", real.deletingLastPathComponent().path, "diff", "HEAD", "--no-color", "--no-ext-diff",
                          "--no-textconv", "--", real.path])
        if let startError = result.startError { return .failed(startError) }
        if result.timedOut { return .failed("git timed out") }
        guard result.status == 0 else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason.isEmpty ? "git exited \(result.status)" : reason)
        }
        return .blocks(parse(result.stdout))
    }

    /// Unified diff text to one block per hunk. Lines before a hunk's `@@` are file headers and are skipped, so a removed
    /// line that starts with `--` inside a hunk is still a removed line. The no-newline marker is dropped.
    static func parse(_ text: String) -> [DiffBlock] {
        var blocks: [DiffBlock] = []
        var current: [DiffLine]?
        func close() {
            if let current { blocks.append(DiffBlock(path: nil, lines: current)) }
            current = nil
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        for line in lines {
            if line.hasPrefix("diff --git ") { close(); continue }
            if line.hasPrefix("@@") { close(); current = []; continue }
            guard current != nil else { continue }
            switch line.first {
            case "+": current?.append(DiffLine(kind: .added, text: String(line.dropFirst())))
            case "-": current?.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
            case "\\": continue
            case " ": current?.append(DiffLine(kind: .unchanged, text: String(line.dropFirst())))
            default: current?.append(DiffLine(kind: .unchanged, text: line))
            }
        }
        close()
        return blocks
    }
}
