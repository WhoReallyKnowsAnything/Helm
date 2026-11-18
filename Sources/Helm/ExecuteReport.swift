import Foundation

/// One `<root>/.planning/phases/<N>/records/reports/plan-<k>.md`, read for display only (D-01, D-08).
/// Status authority stays with `replay-check` (D-03). The exact file name is used, never a glob, because
/// rotation leaves `plan-<k>.<n>.md` siblings.
struct ExecuteReport: Equatable {
    struct Row: Equatable {
        var task: String
        /// The commit cell as written.
        var commit: String
        var note: String
    }

    /// The first line, trimmed.
    var firstLine: String
    /// Everything after the first line, as written.
    var body: String
    var rows: [Row]

    static func parse(_ text: String) -> ExecuteReport {
        let lines = text.components(separatedBy: "\n")
        let first = (lines.first ?? "").trimmingCharacters(in: .whitespaces)
        let body = lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : ""
        return ExecuteReport(firstLine: first, body: body, rows: rows(in: Array(lines.dropFirst())))
    }

    /// The `| Task | Commit | Note |` table: header and `|---|` rows skipped, reading stops at the first non-table line.
    private static func rows(in lines: [String]) -> [Row] {
        var found: [Row] = []
        var inTable = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else {
                if inTable { break }
                continue
            }
            var cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if cells.last == "" { cells.removeLast() }
            if !inTable {
                guard cells.first?.lowercased() == "task" else { continue }
                inTable = true
                continue
            }
            if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
            guard cells.count >= 2 else { continue }
            found.append(Row(task: cells[0], commit: cells[1], note: cells.dropFirst(2).joined(separator: " | ")))
        }
        return found
    }

    /// Nil when the file is missing, unreadable, the phase text is not a plain number or the real path leaves `root`.
    static func read(root: String, phase: String, k: Int) -> ExecuteReport? {
        guard UATStatus.isValidPhase(phase) else { return nil }
        let file = "\(root)/.planning/phases/\(phase)/records/reports/plan-\(k).md"
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        let real = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/"
        guard real.hasPrefix(base), let data = FileManager.default.contents(atPath: real) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
