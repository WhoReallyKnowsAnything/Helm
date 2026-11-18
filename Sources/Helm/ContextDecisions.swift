import Foundation

/// One locked decision from a phase's CONTEXT.md. D-NN restarts per phase, so `phase` is part of the identity.
struct ContextDecision: Equatable {
    let phase: String
    let number: Int
    let area: String
    let text: String

    var label: String { String(format: "D-%02d", number) }
}

enum ContextDecisions {
    private static let phasePattern = #"^[0-9]+(\.[0-9]+)?$"#
    private static let decisionLine = try! NSRegularExpression(pattern: #"^- D-([0-9]+) \((.+?)\): (.+)$"#)
    private static let sections: Set<String> = ["## Durable decisions", "## Decisions"]

    /// Lines of shape `- D-NN (area): text` inside `## Durable decisions` and `## Decisions`, in file order.
    static func parse(_ contextText: String, phase: String) -> [ContextDecision] {
        var inSection = false
        var found: [ContextDecision] = []
        for line in contextText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                inSection = sections.contains(line.trimmingCharacters(in: .whitespaces))
                continue
            }
            let s = String(line)
            guard inSection, let m = decisionLine.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let number = Int(s[Range(m.range(at: 1), in: s)!]) else { continue }
            found.append(ContextDecision(phase: phase, number: number,
                                         area: String(s[Range(m.range(at: 2), in: s)!]),
                                         text: String(s[Range(m.range(at: 3), in: s)!])))
        }
        return found
    }

    /// Up to 3 phases below `current` that hold a CONTEXT.md, newest first. A phase text that is not
    /// `N` or `N.N` is skipped, so no path is ever built from it. Order is numeric; the text stays a string.
    static func earlierPhases(folders: [String], current: String, hasContext: (String) -> Bool) -> [String] {
        guard isPhaseText(current) else { return [] }
        return folders
            .filter { isPhaseText($0) && $0.compare(current, options: .numeric) == .orderedAscending && hasContext($0) }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .prefix(3)
            .map { $0 }
    }

    static func isPhaseText(_ text: String) -> Bool {
        text.range(of: phasePattern, options: .regularExpression) != nil
    }
}
