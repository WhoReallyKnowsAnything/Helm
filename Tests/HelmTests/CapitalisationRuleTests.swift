import Foundation
import Testing

/// Phase 2 D-02: button, menu, tab, screen and sheet titles are in title case. The scan reads literal strings only.
/// Strings built in code (the `Tab` arrays, `primary(...)` titles) are covered by plan 5 tasks 1 and 2, not by the scan.
@Suite struct CapitalisationRuleTests {
    /// Articles, coordinating conjunctions and prepositions of 4 letters or fewer stay lower case between the first and last word.
    private static let small: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet",
        "as", "at", "by", "in", "of", "off", "on", "out", "per", "to", "up", "via", "from", "into", "onto", "over", "with", "than"
    ]

    static func isTitleCase(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        for (i, raw) in words.enumerated() {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "….?!:,()"))
            guard let first = word.first, first.isLetter else { continue }
            if word.contains(where: { $0.isNumber || $0 == "-" || $0 == "/" }) { continue }
            if word.count >= 2, word == word.uppercased() { continue }
            let afterColon = i > 0 && words[i - 1].hasSuffix(":")
            let mustCap = i == 0 || i == words.count - 1 || afterColon || !small.contains(word.lowercased())
            if mustCap ? !first.isUppercase : first.isUppercase { return false }
        }
        return true
    }

    private static let patterns = [
        #"(?<![A-Za-z])(?:Button|KitLabel|Menu|Label)\("([^"\\]*)""#,
        #"label: \{ Text\("([^"\\]*)""#,
        // Both branches of a ternary string passed to a button: Button(cond ? "a" : "b").
        #"(?<![A-Za-z])Button\([^"\n]*\? "([^"\\]*)" : "[^"\\]*""#,
        #"(?<![A-Za-z])Button\([^"\n]*\? "[^"\\]*" : "([^"\\]*)""#,
        #"(?:primaryTitle|cancelTitle|menuTitle): "([^"\\]*)""#,
        #"(?<![A-Za-z])title: "([^"\\]*)""#
    ].map { try! NSRegularExpression(pattern: $0) }

    @Test func theCheckerAcceptsTitleCaseAndFlagsTheRest() {
        for ok in ["Remove from List", "Initialize and Start", "Next: Plan", "Open in VS Code"] {
            #expect(Self.isTitleCase(ok), "\(ok)")
        }
        for bad in ["Run record", "select project", "Fix all"] {
            #expect(!Self.isTitleCase(bad), "\(bad)")
        }
    }

    @Test func everyLiteralButtonMenuAndTitleStringIsTitleCase() throws {
        let folder = "Sources/Helm"
        let files = try #require(FileManager.default.enumerator(atPath: folder)).compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        var found = 0
        var offenders: [String] = []
        for file in files.sorted() {
            let lines = try String(contentsOfFile: "\(folder)/\(file)", encoding: .utf8).components(separatedBy: "\n")
            for (n, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let range = NSRange(line.startIndex..., in: line)
                for regex in Self.patterns {
                    for match in regex.matches(in: line, range: range) {
                        guard let r = Range(match.range(at: 1), in: line) else { continue }
                        // A string that starts with a digit quotes a Claude Code prompt option ("2. Yes, ..."), not a title.
                        if line[r].first?.isNumber == true { continue }
                        found += 1
                        if !Self.isTitleCase(String(line[r])) { offenders.append("\(file):\(n + 1) \"\(line[r])\"") }
                    }
                }
            }
        }
        #expect(found >= 30, "the scan found only \(found) strings")
        #expect(offenders.isEmpty, "Not title case:\n\(offenders.joined(separator: "\n"))")
    }
}
