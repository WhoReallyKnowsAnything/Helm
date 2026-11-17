import Foundation

/// The only code that answers a `can_use_tool` request (D-02). It appends one `control_response` line to a session's inbox.
enum ControlAnswerWriter {
    static let denyMessage = "Denied from Helm."

    /// Allow returns the request's `input` bytes unchanged as `updatedInput` (D-06). The bytes are spliced in, never re-encoded.
    static func allowLine(for request: PermissionRequest) -> Data? {
        guard let id = jsonString(request.requestId) else { return nil }
        var line = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"#.utf8)
        line.append(id)
        line.append(Data(#","response":{"behavior":"allow","updatedInput":"#.utf8))
        line.append(request.input)
        line.append(Data("}}}".utf8))
        return line
    }

    static func denyLine(for request: PermissionRequest) -> Data? {
        let line: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success", "request_id": request.requestId,
                "response": ["behavior": "deny", "message": denyMessage],
            ] as [String: Any],
        ]
        return try? JSONSerialization.data(withJSONObject: line)
    }

    /// The AskUserQuestion answer (PROBE.md verdict `answers`): allow with the request `input` plus an `answers` map keyed by
    /// question text. A multi-select value is its labels joined with ", ". The input is re-encoded because a field is added.
    static func answersLine(for request: PermissionRequest, picks: [String: [String]]) -> Data? {
        guard var input = (try? JSONSerialization.jsonObject(with: request.input)) as? [String: Any] else { return nil }
        input["answers"] = picks.mapValues { $0.joined(separator: ", ") }
        let line: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success", "request_id": request.requestId,
                "response": ["behavior": "allow", "updatedInput": input],
            ] as [String: Any],
        ]
        return try? JSONSerialization.data(withJSONObject: line)
    }

    /// Appends the answer plus a newline to `inbox`. Blocks; callers run it off the main actor.
    /// No O_CREAT, as in `InboxDelivery`: a missing inbox is a failure and never creates a file.
    static func append(_ request: PermissionRequest, allow: Bool, inbox: String) -> InboxDelivery.Outcome {
        write(allow ? allowLine(for: request) : denyLine(for: request), inbox: inbox)
    }

    static func appendAnswers(_ request: PermissionRequest, picks: [String: [String]], inbox: String) -> InboxDelivery.Outcome {
        write(answersLine(for: request, picks: picks), inbox: inbox)
    }

    private static func write(_ line: Data?, inbox: String) -> InboxDelivery.Outcome {
        guard var data = line else {
            return .failed("Could not build the answer.")
        }
        data.append(0x0A)
        let fd = Darwin.open(inbox, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return .failed("Could not open the inbox: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else {
            return .failed("Could not write to the inbox: \(written < 0 ? String(cString: strerror(errno)) : "short write")")
        }
        return .sent
    }

    /// The id as a quoted JSON string, quotes included.
    private static func jsonString(_ text: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)
    }
}
