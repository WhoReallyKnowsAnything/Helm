import Foundation

/// The text lines under a node: context %, then `model · effort` (INFO-02), from the node's own out log (D-11).
enum NodeInfo {
    static let noData = "no data"

    /// Lines per node key. The log's model and effort win; a worker row's launch values fill what the log lacks (D-13).
    /// A node with nothing shows `noData`. No staleness rule: a quiet log keeps its last values.
    static func lines(log: [String: SessionStatusStore.Entry], nodes: [WorkerTreeNode], rows: [WorkerRow]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for node in nodes {
            let row = node.kind == .worker ? rows.first { $0.agentId == node.key } : nil
            let fold = log[node.key]?.fold
            let context = fold?.contextPercent.map { "\($0)%" }
            let model = fold?.model.flatMap(shortModel) ?? row?.model
            let lines = [context, modelLine(model, fold?.effort ?? row?.effort)].compactMap { $0 }
            result[node.key] = lines.isEmpty ? [noData] : lines
        }
        return result
    }

    /// `claude-haiku-5-5` gives `Haiku 5.5`. A trailing 8-digit date and a `[1m]` suffix are dropped. An id of another
    /// shape shows without `claude-`; an empty id gives nil.
    static func shortModel(_ id: String) -> String? {
        var name = id.hasPrefix("claude-") ? String(id.dropFirst(7)) : id
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        var parts = name.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, parts.count > 1, family.allSatisfy(\.isLetter),
              parts.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return name.isEmpty ? nil : name }
        return family.prefix(1).uppercased() + family.dropFirst() + " " + parts.dropFirst().joined(separator: ".")
    }

    private static func modelLine(_ model: String?, _ effort: String?) -> String? {
        let capitalizedEffort = effort.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let text = [model, capitalizedEffort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }
}
