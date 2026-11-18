import Foundation

/// Whether the milestone's version tag exists, locally and on origin. Read-only. Every git call blocks, so callers run it
/// off the main actor. The tag spelling is not pinned by any file, so the match is loose and a miss shows absent or unknown,
/// never a false present.
enum MilestoneLandTags {
    enum Answer: Equatable {
        case present(String)
        case absent
        /// Why no answer: no version, no origin, or the first line of the git failure.
        case unknown(String)
    }

    typealias RunGit = ([String]) -> ProcessResult

    /// The first `Milestone v<digits and dots>` in the worktree's ROADMAP.md, else its PROJECT.md, else the project folder's copies.
    static func version(project: String, worktree: String?,
                        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> String? {
        var folders: [String] = []
        if let wt = UATScreenLoader.insideWorktree(worktree, project: project) { folders.append(wt) }
        folders.append(project)
        for folder in folders {
            for file in ["ROADMAP.md", "PROJECT.md"] {
                guard let text = read(folder + "/.planning/" + file),
                      let range = text.range(of: #"Milestone v([0-9]+(?:\.[0-9]+)*)"#, options: .regularExpression) else { continue }
                return String(text[range].dropFirst("Milestone v".count))
            }
        }
        return nil
    }

    static func local(version: String?, project: String, runGit: RunGit = { FolderCheck.runGit($0) }) -> Answer {
        guard let version else { return .unknown(noVersion) }
        let result = runGit(["-C", project, "tag", "--list"])
        if let why = MilestoneLandFacts.problem(result, tool: "git tag") { return .unknown(why) }
        return answer(names: result.stdout.split(whereSeparator: \.isNewline).map(String.init), version: version)
    }

    /// The network call. The caller runs it on open and on Refresh only.
    static func origin(version: String?, project: String, runGit: RunGit = { FolderCheck.runGit($0) }) -> Answer {
        guard let version else { return .unknown(noVersion) }
        let remotes = runGit(["-C", project, "remote"])
        if let why = MilestoneLandFacts.problem(remotes, tool: "git remote") { return .unknown(why) }
        guard remotes.stdout.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "origin" }) else {
            return .unknown("no origin")
        }
        let result = runGit(["-C", project, "ls-remote", "--tags", "origin"])
        if let why = MilestoneLandFacts.problem(result, tool: "git ls-remote") { return .unknown(why) }
        let names = result.stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard !line.hasSuffix("^{}"), let range = line.range(of: "refs/tags/") else { return nil }
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return answer(names: names, version: version)
    }

    static let noVersion = "unknown: no milestone version found"

    /// A tag matches when its name, after one leading `v`, equals the version or starts with it and a dot.
    static func matches(_ name: String, version: String) -> Bool {
        let bare = name.hasPrefix("v") ? String(name.dropFirst()) : name
        return bare == version || bare.hasPrefix(version + ".")
    }

    private static func answer(names: [String], version: String) -> Answer {
        names.first { matches($0, version: version) }.map(Answer.present) ?? .absent
    }
}
