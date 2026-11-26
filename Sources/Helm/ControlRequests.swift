import Foundation

/// One `can_use_tool` request that waits for an answer (D-01).
struct PermissionRequest: Equatable {
    let requestId: String
    let toolName: String
    let toolUseId: String
    /// The `input` value as the exact bytes of the out-log line. The allow answer returns these bytes (D-06).
    let input: Data
    let displayName: String?
    /// Tool name and the whole input, escaped by `GateHold.displayText`. Never cut (D-02).
    let text: String
    /// The `decision_reason`, escaped the same way.
    let reason: String?
}

/// Folds out-log lines into the requests that are still open. Decodes tolerantly: a malformed line or a line with
/// a missing field adds nothing. Feed lines as they arrive; start over with a new value after a reader reset.
struct ControlRequests {
    /// Oldest first.
    private(set) var pending: [PermissionRequest] = []

    mutating func feed(_ lines: [String]) {
        for line in lines { feed(line) }
    }

    mutating func feed(_ line: String) {
        // Cheap screen first: most lines are stream deltas.
        guard line.utf8Contains(anyOf: ["control_request", "control_cancel_request", "control_response", "tool_result", "\"result\"", "\"init\""]),
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        switch object["type"] as? String {
        case "control_request": open(line, object)
        case "control_cancel_request", "control_response":
            if let id = object["request_id"] as? String ?? (object["response"] as? [String: Any])?["request_id"] as? String {
                pending.removeAll { $0.requestId == id }
            }
        case "result": pending = []
        case "system": if object["subtype"] as? String == "init" { pending = [] }
        case "user":
            let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in blocks where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { pending.removeAll { $0.toolUseId == id } }
            }
        default: break
        }
    }

    private mutating func open(_ line: String, _ object: [String: Any]) {
        guard let id = object["request_id"] as? String,
              let request = object["request"] as? [String: Any], request["subtype"] as? String == "can_use_tool",
              let tool = request["tool_name"] as? String, request["input"] != nil,
              let toolUse = request["tool_use_id"] as? String else { return }
        let bytes = Array(line.utf8)
        guard let requestRange = RawJSON.member("request", in: bytes, at: 0),
              let inputRange = RawJSON.member("input", in: bytes, at: requestRange.lowerBound),
              let raw = try? JSONSerialization.jsonObject(with: Data(bytes[inputRange]), options: .fragmentsAllowed),
              let json = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return }
        pending.removeAll { $0.requestId == id }
        pending.append(PermissionRequest(
            requestId: id, toolName: tool, toolUseId: toolUse, input: Data(bytes[inputRange]),
            displayName: request["display_name"] as? String,
            text: GateHold.displayText(tool + " " + String(decoding: json, as: UTF8.self)),
            reason: (request["decision_reason"] as? String).map { GateHold.displayText($0) }))
    }
}

/// Finds the bytes of one member of a JSON object without decoding it, so a number such as 1.0 or a large
/// integer reaches the answer exactly as the session wrote it.
enum RawJSON {
    /// The byte range of the value of `key` in the object that starts at or after `start`. Nil when absent or malformed.
    static func member(_ key: String, in b: [UInt8], at start: Int) -> Range<Int>? {
        var i = skipSpace(b, start)
        guard i < b.count, b[i] == UInt8(ascii: "{") else { return nil }
        i += 1
        while true {
            i = skipSpace(b, i)
            guard i < b.count, b[i] != UInt8(ascii: "}") else { return nil }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            guard b[i] == UInt8(ascii: "\""), let keyEnd = skipString(b, i) else { return nil }
            // shortcut: the key is compared undecoded, so a key written with escapes never matches; upgrade if a session does that.
            let name = String(decoding: b[(i + 1)..<(keyEnd - 1)], as: UTF8.self)
            i = skipSpace(b, keyEnd)
            guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
            i = skipSpace(b, i + 1)
            guard let end = skipValue(b, i) else { return nil }
            if name == key { return i..<end }
            i = end
        }
    }

    private static func skipSpace(_ b: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
        return i
    }

    /// `start` is the opening quote. Returns the index after the closing quote.
    private static func skipString(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start + 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return nil
    }

    private static func skipValue(_ b: [UInt8], _ start: Int) -> Int? {
        guard start < b.count else { return nil }
        switch b[start] {
        case UInt8(ascii: "\""): return skipString(b, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "\""):
                    guard let end = skipString(b, i) else { return nil }
                    i = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 }
            return i > start ? i : nil
        }
    }
}
