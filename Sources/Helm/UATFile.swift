import Foundation

/// A parsed UAT.md (pure, no I/O). The app reads it for display only; counts and result come from `uat status`.
struct UATFile: Equatable {
    struct Item: Equatable {
        var k: Int
        var name: String
        var expected: String
        /// Cadence's own words: pass, fail, pending, skipped, blocked (or others it adds, kept as written).
        var status: String
        /// nil is the user's own answer; "verifier" and "model" are named.
        var source: String?
        var reason: String?
        var reported: String?
        /// Lines of any other field, raw.
        var other: [String]

        /// The `reason` line, else the `reported` line.
        var note: String? { reason ?? reported }
    }

    enum Outcome: Equatable {
        case items([Item])
        /// `fields_version` is not 1; `version` is its text ("missing" when absent). No items.
        case unsupported(version: String)
    }

    static let supportedVersion = "1"
    private static let known: Set<String> = ["expected", "status", "source", "reason", "reported"]

    static func parse(_ text: String) -> Outcome {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var version = "missing"
        var index = 0
        if lines.first == "---" {
            index = 1
            while index < lines.count, lines[index] != "---" {
                if let (key, value) = field(lines[index]), key == "fields_version" { version = value }
                index += 1
            }
        }
        guard version == supportedVersion else { return .unsupported(version: version) }
        var items: [Item] = []
        var current: (k: Int, name: String, fields: [String: String], other: [String])?
        func close() {
            guard let c = current else { return }
            items.append(Item(k: c.k, name: c.name, expected: c.fields["expected"] ?? "", status: c.fields["status"] ?? "",
                              source: c.fields["source"], reason: c.fields["reason"], reported: c.fields["reported"], other: c.other))
            current = nil
        }
        for line in lines[min(index + 1, lines.count)...] {
            if line.hasPrefix("## ") || line.hasPrefix("# ") { close(); continue }
            if line.hasPrefix("### ") {
                close()
                // A heading that is not "N. Name" is a hand-added section, not an item.
                if let head = line.dropFirst(4).range(of: #"^[0-9]+\. "#, options: .regularExpression) {
                    let rest = line.dropFirst(4)
                    let k = Int(rest[rest.startIndex..<rest.index(before: head.upperBound)].dropLast()) ?? 0
                    current = (k, String(rest[head.upperBound...]), [:], [])
                }
                continue
            }
            guard current != nil, let (key, value) = field(line) else { continue }
            if known.contains(key) { current?.fields[key] = value } else { current?.other.append(line) }
        }
        close()
        return .items(items)
    }

    /// `key: value` with a lower-case key. The value stays whole, including any `: ` inside it.
    private static func field(_ line: String) -> (String, String)? {
        guard let range = line.range(of: #"^[a-z_]+: "#, options: .regularExpression) else { return nil }
        let key = String(line[line.startIndex..<line.index(range.upperBound, offsetBy: -2)])
        return (key, String(line[range.upperBound...]))
    }
}
