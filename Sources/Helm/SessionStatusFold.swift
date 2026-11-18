import Foundation

/// Folds one session's out-log lines into its turn state and display data (D-01, D-02, D-11 to D-15). Pure and
/// incremental, no file IO and no clock: the store adds the file time. A malformed line or an unknown event changes nothing.
struct SessionStatusFold: Equatable {
    /// A rate-limit window exactly as the log records it (`utilization` 0 to 1, `resetsAt` epoch seconds).
    struct RawWindow: Equatable {
        let utilization: Double
        let resetsAt: Double
    }

    /// Nil until the first turn event or `result`. True from a turn event until its `result`, unless that
    /// `result` has `queued_turn_count` above 0, which keeps the turn going.
    private(set) var turnInProgress: Bool?
    /// The newest of the `system/init` model, a `set_model` response model and a single-key `result.modelUsage` (D-12).
    private(set) var model: String?
    /// The level from a "Set effort level to X" result text, lowercased (D-13).
    private(set) var effort: String?
    /// Last iteration's tokens over the current model's `contextWindow`, whole percent; nil before the first `result` (D-14).
    private(set) var contextPercent: Int?
    /// Newest value per window; a window missing from a newer event keeps the earlier one (D-15).
    private(set) var fiveHour: RawWindow?
    private(set) var sevenDay: RawWindow?

    mutating func feed(_ lines: [String]) {
        for line in lines { feed(line) }
    }
    mutating func feed(_ line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "result":
            turnInProgress = ((object["queued_turn_count"] as? Int) ?? 0) > 0
            foldResult(object)
        case "system":
            if object["subtype"] as? String == "init", let m = object["model"] as? String { model = m }
        case "control_response":
            let response = (object["response"] as? [String: Any])?["response"] as? [String: Any]
            if let m = response?["model"] as? String { model = m }
        case "rate_limit_event":
            let windows = ((object["rate_limit_info"] as? [String: Any])?["unifiedWindows"]) as? [String: Any]
            fiveHour = Self.window(windows?["five_hour"]) ?? fiveHour
            sevenDay = Self.window(windows?["seven_day"]) ?? sevenDay
        // Only these events happen inside a turn. `control_*`, `rate_limit_event`, `system` and the reply to a local
        // command (`<local-command-stdout>`, such as "Set model to ...") also arrive while idle, so they start nothing.
        case "stream_event", "assistant", "tool_progress":
            turnInProgress = true
        case "user":
            let content = (object["message"] as? [String: Any])?["content"]
            if let text = content as? String, text.contains("<local-command-") { return }
            turnInProgress = true
        default: break
        }
    }

    private mutating func foldResult(_ object: [String: Any]) {
        let usage = object["modelUsage"] as? [String: Any] ?? [:]
        if usage.count == 1, let key = usage.keys.first { model = key }
        if let text = object["result"] as? String, let level = Self.effortLevel(in: text) { effort = level }
        let last = ((object["usage"] as? [String: Any])?["iterations"] as? [[String: Any]])?.last
        guard let last, let model, let window = (usage[model] as? [String: Any])?["contextWindow"] as? Double,
              window > 0 else { return }
        let tokens = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .reduce(0.0) { $0 + ((last[$1] as? Double) ?? 0) }
        contextPercent = Int((tokens / window * 100).rounded())
    }

    /// Reads the raw log text, so both Claude's "high" and a capitalised "High" give `high`.
    private static func effortLevel(in text: String) -> String? {
        guard let range = text.range(of: "Set effort level to ", options: .caseInsensitive) else { return nil }
        let word = text[range.upperBound...].prefix { $0.isLetter }
        return word.isEmpty ? nil : word.lowercased()
    }

    private static func window(_ value: Any?) -> RawWindow? {
        guard let dict = value as? [String: Any], let u = dict["utilization"] as? Double,
              let r = dict["resetsAt"] as? Double else { return nil }
        return RawWindow(utilization: u, resetsAt: r)
    }
}
