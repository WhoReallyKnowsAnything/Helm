import Foundation

/// One `PLAN.md` or `PLAN-<k>.md` read into its parts. Every captured text is kept as written (trimmed at both ends only).
/// Text that does not match the shape never fails the parse: `raw` is always carried and `tasks` may be empty.
struct ParsedPlan: Equatable {
    struct Task: Equatable {
        var name: String
        var files: [String]
        var action: String
        var verify: String
    }

    var phase: String?
    var plan: String?
    var requirements: [String]
    var files: [String]
    var dependsOn: [String]?
    var heading: String?
    var mustBeTrue: [String]
    var tasks: [Task]
    var raw: String
}

enum PlanReviewParser {
    static func parse(_ text: String) -> ParsedPlan {
        let lines = text.components(separatedBy: "\n")
        let (front, bodyStart) = frontmatter(lines)
        let body = Array(lines[bodyStart...])
        return ParsedPlan(
            phase: front.scalar("phase"), plan: front.scalar("plan"),
            requirements: front.list("requirements") ?? [], files: front.list("files") ?? [],
            dependsOn: front.list("depends_on"),
            heading: body.first { $0.hasPrefix("# ") },
            mustBeTrue: mustBeTrue(body), tasks: tasks(body), raw: text)
    }

    private struct Front {
        var values: [String: [String]] = [:]
        var inline: Set<String> = []
        func scalar(_ key: String) -> String? { values[key]?.first }
        func list(_ key: String) -> [String]? { values[key] }
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" else { return t }
        return String(t.dropFirst().dropLast())
    }

    /// The frontmatter and the index of the first line after it.
    private static func frontmatter(_ lines: [String]) -> (Front, Int) {
        var front = Front()
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return (front, 0) }
        var key: String?
        for line in lines[1..<end] {
            if let m = line.range(of: #"^[A-Za-z_]+:"#, options: .regularExpression) {
                let k = String(line[m].dropLast())
                let rest = line[m.upperBound...].trimmingCharacters(in: .whitespaces)
                key = k
                if rest.hasPrefix("[") {
                    let inner = rest.drop { $0 == "[" }.prefix { $0 != "]" }
                    front.values[k] = inner.split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
                } else if rest.isEmpty || rest.hasPrefix("#") {
                    front.values[k] = []
                } else {
                    front.values[k] = [unquote(rest)]
                }
            } else if let key, line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                let item = line.trimmingCharacters(in: .whitespaces).dropFirst(2)
                front.values[key, default: []].append(unquote(String(item)))
            }
        }
        return (front, end + 1)
    }

    private static func mustBeTrue(_ body: [String]) -> [String] {
        var inSection = false, out: [String] = []
        for line in body {
            if line.hasPrefix("## ") { inSection = line.hasPrefix("## Must be true when done"); continue }
            if inSection, line.hasPrefix("- ") { out.append(String(line.dropFirst(2))) }
        }
        return out
    }

    private static let markers = ["- **Files:**", "- **Action:**", "- **Verify:**"]

    private static func tasks(_ body: [String]) -> [ParsedPlan.Task] {
        var out: [ParsedPlan.Task] = []
        var name: String?
        var field: String?
        var values: [String: [String]] = [:]

        func flush() {
            guard let name else { return }
            func joined(_ k: String) -> String { (values[k] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            let files = joined("Files").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            out.append(.init(name: name, files: files, action: joined("Action"), verify: joined("Verify")))
        }

        for line in body {
            if let m = line.range(of: #"^### Task [0-9]+:"#, options: .regularExpression) {
                flush()
                name = line[m.upperBound...].trimmingCharacters(in: .whitespaces)
                field = nil; values = [:]
            } else if line.hasPrefix("## ") || line.hasPrefix("### ") {
                flush()
                name = nil; field = nil; values = [:]
            } else if name != nil {
                if let marker = markers.first(where: { line.hasPrefix($0) }) {
                    field = String(marker.dropFirst(4).dropLast(3))
                    values[field!] = [String(line.dropFirst(marker.count))]
                } else if let field {
                    values[field, default: []].append(line)
                }
            }
        }
        flush()
        return out
    }
}
