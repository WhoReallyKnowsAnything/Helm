import Foundation

/// The `- [ ] ACn: text` lines of a CONTEXT.md `## Acceptance criteria` section, each kept whole. Every other section is ignored.
enum ContextCriteria {
    static func parse(_ text: String) -> [String] {
        var inSection = false, out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inSection = line.hasPrefix("## Acceptance criteria"); continue }
            if inSection, line.range(of: #"^- \[[ xX]\] AC[0-9]+:"#, options: .regularExpression) != nil { out.append(line) }
        }
        return out
    }
}
