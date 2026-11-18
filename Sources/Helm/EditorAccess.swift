import Foundation

/// D-02: whether the editor may save a file. Read-only carries the reason the header shows.
enum EditorAccess: Equatable {
    case editable
    case readOnly(String)

    var isEditable: Bool { self == .editable }
    var reason: String? {
        if case .readOnly(let reason) = self { return reason }
        return nil
    }

    /// A file in a live worker's worktree (status not `merged` and not `dead`) or under `.planning/` is read-only.
    static func resolve(_ file: URL, project: URL, rows: [WorkerRow]) -> EditorAccess {
        let real = canonical(file)
        if let row = owner(of: real, rows: rows), row.status != "merged", row.status != "dead" {
            return .readOnly("in the worktree of worker \(row.agentId), which is still live")
        }
        let projectParts = canonical(project).pathComponents
        let parts = real.pathComponents
        let below = parts.starts(with: projectParts) ? Array(parts.dropFirst(projectParts.count)) : parts
        if below.contains(".planning") {
            return .readOnly("Cadence owns the files under .planning")
        }
        return .editable
    }

    /// The row, of any status, whose worktree holds `file`. Whole path components, after resolving symlinks.
    static func owner(of file: URL, rows: [WorkerRow]) -> WorkerRow? {
        let parts = canonical(file).pathComponents
        return rows.first { row in
            guard let path = row.worktreePath, !path.isEmpty else { return false }
            return parts.starts(with: canonical(URL(fileURLWithPath: path)).pathComponents)
        }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
