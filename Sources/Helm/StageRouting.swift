import Foundation

/// The session model and effort the board names for each stage's worker (D-09). Stored in app settings, never in
/// `.planning/` or Cadence config. `defaults` is a parameter, so tests never touch `.standard`.
struct StageRouting {
    struct Entry: Equatable {
        var model: String?
        var effort: String?

        /// `dispatch-task.sh` refuses opus with xhigh or max, so the board refuses to send that pair.
        var refusal: String? {
            guard model == "opus", let effort, effort == "xhigh" || effort == "max" else { return nil }
            return "Opus with effort \(effort) is refused by dispatch. Pick high or lower."
        }
    }

    static let stages: [WorkflowGates.Stage] = [.context, .plan, .execute, .verify, .milestone]
    static let models = ["haiku", "sonnet", "opus"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    /// The stored word for "name nothing".
    static let none = "none"

    /// Context and milestone start on opus/high. Plan, execute and verify name nothing.
    static func fallback(_ stage: WorkflowGates.Stage) -> Entry {
        switch stage {
        case .context, .milestone: return Entry(model: "opus", effort: "high")
        default: return Entry(model: nil, effort: nil)
        }
    }

    /// The "utility" row covers every chip and every config fix (D-05). Same storage as the stage rows.
    static let utility = "utility"
    static let utilityFallback = Entry(model: "sonnet", effort: nil)

    static func modelKey(_ stage: WorkflowGates.Stage) -> String { modelKey(stage.rawValue) }
    static func effortKey(_ stage: WorkflowGates.Stage) -> String { effortKey(stage.rawValue) }
    static func modelKey(_ name: String) -> String { "stageRouting.\(name).model" }
    static func effortKey(_ name: String) -> String { "stageRouting.\(name).effort" }

    let defaults: UserDefaults

    func entry(for stage: WorkflowGates.Stage) -> Entry { entry(named: stage.rawValue, fallback: Self.fallback(stage)) }

    func set(_ entry: Entry, for stage: WorkflowGates.Stage) { set(entry, named: stage.rawValue) }

    func utilityEntry() -> Entry { entry(named: Self.utility, fallback: Self.utilityFallback) }

    func setUtility(_ entry: Entry) { set(entry, named: Self.utility) }

    private func entry(named name: String, fallback base: Entry) -> Entry {
        Entry(model: read(Self.modelKey(name), base.model), effort: read(Self.effortKey(name), base.effort))
    }

    private func set(_ entry: Entry, named name: String) {
        defaults.set(entry.model ?? Self.none, forKey: Self.modelKey(name))
        defaults.set(entry.effort ?? Self.none, forKey: Self.effortKey(name))
    }

    private func read(_ key: String, _ fallback: String?) -> String? {
        guard let stored = defaults.string(forKey: key) else { return fallback }
        return stored == Self.none ? nil : stored
    }
}
