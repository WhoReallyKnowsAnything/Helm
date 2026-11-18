import Foundation

/// Reads back the CAPTURE.md bullets that hold the override reason the view sent. Read-only, no watcher.
/// Grammar: `cadence-core/references/capture-grammar.md`. Only `## Todos`, `## Seeds` and `## Notes` are walked, and a
/// bullet is a column-0 `- ` line. The sentence is the worker's own, so the match is best effort.
enum MilestoneCapture {
    static let walked: Set<String> = ["## todos", "## seeds", "## notes"]

    /// The reason as the line carried it, with runs of whitespace collapsed. Nil when it cleans to nothing.
    static func flatten(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The worktree copy when it is inside `<project>/.claude/worktrees/` and no symlink leaves it, else the project copy.
    static func file(project: String, worktree: String?) -> String? {
        let relative = "/.planning/CAPTURE.md"
        if let wt = UATScreenLoader.insideWorktree(worktree, project: project) {
            let path = wt + relative
            if FileManager.default.fileExists(atPath: path),
               URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(wt + "/") { return path }
        }
        let path = project + relative
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func bullets(in text: String, holding reason: String) -> [String] {
        let needle = flatten(reason).lowercased()
        guard !needle.isEmpty else { return [] }
        var inWalk = false
        var found: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") {
                inWalk = walked.contains(line.trimmingCharacters(in: .whitespaces).lowercased())
                continue
            }
            guard inWalk, line.hasPrefix("- ") else { continue }
            let bullet = flatten(String(line))
            if bullet.lowercased().contains(needle) { found.append(bullet) }
        }
        return found
    }

    static func read(project: String, worktree: String?, reason: String?,
                     readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> [String] {
        guard let reason, let path = file(project: project, worktree: worktree), let text = readFile(path) else { return [] }
        return bullets(in: text, holding: reason)
    }
}
