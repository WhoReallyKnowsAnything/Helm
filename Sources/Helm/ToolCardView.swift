import Foundation

let toolSummaryCap = 100
/// Characters of a result drawn when expanded; one result line can be 154 KB.
let toolResultCap = 4000

/// One line for a tool call: the first present string among the usual keys, else the first string value
/// (keys sorted so the pick is stable), cut to its first line and `toolSummaryCap` characters.
func toolSummary(_ input: JSONValue) -> String {
    guard case .object(let fields) = input else { return "" }
    let preferred = ["command", "file_path", "path", "pattern", "query", "description"]
    let picked = preferred.lazy.compactMap { fields[$0]?.string }.first
        ?? fields.keys.sorted().lazy.compactMap { fields[$0]?.string }.first
    guard let picked else { return "" }
    let line = picked.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    return line.count > toolSummaryCap ? String(line.prefix(toolSummaryCap)) + "…" : line
}

/// The input as indented JSON for the expanded card.
func formattedInput(_ input: JSONValue) -> String {
    func plain(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let items): return items.map(plain)
        case .object(let fields): return fields.mapValues(plain)
        }
    }
    let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
    guard let data = try? JSONSerialization.data(withJSONObject: plain(input), options: options) else { return "" }
    return String(decoding: data, as: UTF8.self)
}
