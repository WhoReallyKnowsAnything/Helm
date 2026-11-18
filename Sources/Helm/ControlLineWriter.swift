import Foundation

/// Builds and appends the session control lines (D-09): interrupt, set_model and the read-only mcp_status. The subtype is a closed enum, so no other
/// control request can be built here. Answers to permission requests belong to `ControlAnswerWriter` alone.
enum ControlLineWriter {
    enum Subtype: String, CaseIterable {
        case interrupt
        case setModel = "set_model"
        case mcpStatus = "mcp_status"
    }

    /// The names in `.planning/phases/3/MODELS.md` (ACCEPTED lines), in picker order.
    static let models = ["opus", "sonnet", "haiku", "opus[1m]", "sonnet[1m]"]
    /// The levels `claude --help` prints.
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static func interruptLine(id: String = "app-" + UUID().uuidString) -> Data? { line(.interrupt, model: nil, id: id) }

    static func mcpStatusLine() -> Data? { line(.mcpStatus, model: nil) }

    static func setModelLine(_ model: String) -> Data? {
        models.contains(model) ? line(.setModel, model: model) : nil
    }

    private static func line(_ subtype: Subtype, model: String?, id: String = "app-" + UUID().uuidString) -> Data? {
        var request: [String: Any] = ["subtype": subtype.rawValue]
        if let model { request["model"] = model }
        let object: [String: Any] = ["type": "control_request", "request_id": id, "request": request]
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// Blocks; callers run these off the main actor.
    static func appendInterrupt(id: String = "app-" + UUID().uuidString, inbox: String) -> InboxDelivery.Outcome {
        write(interruptLine(id: id), inbox: inbox)
    }

    static func appendMcpStatus(inbox: String) -> InboxDelivery.Outcome { write(mcpStatusLine(), inbox: inbox) }

    static func appendSetModel(_ model: String, inbox: String) -> InboxDelivery.Outcome {
        guard models.contains(model) else { return .refused("Unknown model. Nothing was sent.") }
        return write(setModelLine(model), inbox: inbox)
    }

    static func appendEffort(_ level: String, inbox: String) -> InboxDelivery.Outcome {
        guard efforts.contains(level) else { return .refused("Unknown effort level. Nothing was sent.") }
        return InboxDelivery.append("/effort \(level)", inbox: inbox)
    }

    /// No O_CREAT, one write call: the same technique as `InboxDelivery`.
    private static func write(_ line: Data?, inbox: String) -> InboxDelivery.Outcome {
        guard var data = line else { return .failed("Could not build the control line.") }
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
}
