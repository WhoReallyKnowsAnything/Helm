import Foundation

struct DiffLine: Equatable {
    enum Kind: Equatable { case unchanged, removed, added }
    let kind: Kind
    let text: String
}

struct DiffBlock: Equatable {
    let path: String?
    let lines: [DiffLine]
}

/// Builds removed/added line blocks from the input of an edit tool (D-04), or nil when the tool is not an edit
/// or its fields are missing or not strings. The diff comes from the input, never from the result text.
func lineDiff(tool: String, input: JSONValue) -> [DiffBlock]? {
    switch tool {
    case "Edit":
        guard let (old, new) = strings(input, "old_string", "new_string") else { return nil }
        return [block(input["file_path"]?.string, old, new)]
    case "MultiEdit":
        guard case .array(let edits)? = input["edits"], !edits.isEmpty else { return nil }
        let path = input["file_path"]?.string
        let blocks = edits.compactMap { strings($0, "old_string", "new_string").map { block(path, $0.0, $0.1) } }
        return blocks.count == edits.count ? blocks : nil
    case "Write":
        guard let content = input["content"]?.string else { return nil }
        return [DiffBlock(path: input["file_path"]?.string, lines: split(content).map { DiffLine(kind: .added, text: $0) })]
    case "mcp__lean-ctx__ctx_patch":
        var entries = [input]
        if case .array(let ops)? = input["ops"] { entries = ops }
        let blocks = entries.compactMap { entry -> DiffBlock? in
            // Line and hash ops carry new_text too, so only the replace ops count.
            if let op = (entry["op"] ?? input["op"])?.string, op != "replace_unique", op != "replace_all" { return nil }
            guard let (old, new) = strings(entry, "find", "replace") ?? strings(entry, "old_text", "new_text") else { return nil }
            return block((entry["path"] ?? input["path"])?.string, old, new)
        }
        return blocks.isEmpty ? nil : blocks
    default:
        return nil
    }
}

private func strings(_ value: JSONValue, _ a: String, _ b: String) -> (String, String)? {
    guard let x = value[a]?.string, let y = value[b]?.string else { return nil }
    return (x, y)
}

private func split(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

private func block(_ path: String?, _ old: String, _ new: String) -> DiffBlock {
    let before = split(old), after = split(new)
    let diff = after.difference(from: before)
    var removed = Set<Int>(), inserted = Set<Int>()
    for change in diff {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }
    var lines: [DiffLine] = []
    var i = 0, j = 0
    while i < before.count || j < after.count {
        if i < before.count, removed.contains(i) {
            lines.append(DiffLine(kind: .removed, text: before[i])); i += 1
        } else if j < after.count, inserted.contains(j) {
            lines.append(DiffLine(kind: .added, text: after[j])); j += 1
        } else if i < before.count {
            lines.append(DiffLine(kind: .unchanged, text: before[i])); i += 1; j += 1
        } else {
            break
        }
    }
    return DiffBlock(path: path, lines: lines)
}
