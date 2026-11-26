import Foundation

/// One session's control state, folded from its out-log lines (D-09, D-10): the current model and the last interrupt.
/// Pure and incremental. Nothing is stored on disk. The effort has no source in the log (MODELS.md), so it is not here.
struct SessionControl: Equatable {
    enum Phase: Equatable {
        /// The app appended the interrupt; no `control_response` for it yet.
        case sending
        /// The `control_response` for it arrived (success or error).
        case answered
        /// A `result` with `error_during_execution` followed the response.
        case ended
    }

    /// The model name as the log writes it, such as `claude-haiku-5-5`. Nil until an `init` or a `set_model` response.
    private(set) var model: String?
    private(set) var interruptId: String?
    private(set) var interrupt: Phase?

    /// The app calls this before it appends the interrupt line, so a fast response cannot be missed.
    mutating func noteInterrupt(id: String) {
        interruptId = id
        interrupt = .sending
    }

    mutating func feed(_ lines: [String]) {
        for line in lines { feed(line) }
    }

    mutating func feed(_ line: String) {
        // Cheap screen first: most lines are stream deltas.
        guard line.utf8Contains(anyOf: ["control_response", "\"result\"", "\"init\""]),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        switch object["type"] as? String {
        case "system":
            if object["subtype"] as? String == "init", let name = object["model"] as? String { model = name }
        case "control_response":
            guard let response = object["response"] as? [String: Any] else { return }
            if response["subtype"] as? String == "success",
               let name = (response["response"] as? [String: Any])?["model"] as? String, !name.isEmpty { model = name }
            if interrupt == .sending, response["request_id"] as? String == interruptId { interrupt = .answered }
        case "result":
            if interrupt == .answered, object["subtype"] as? String == "error_during_execution" { interrupt = .ended }
        default: break
        }
    }
}
