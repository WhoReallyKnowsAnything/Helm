import Foundation

/// The one inbox line a board press sends (D-07). Pure: no I/O, no text from STATE.md enters the line.
/// Grammar: `Cadence stage: ` then ordered `name=value` fields, then, only on an override, ` reason: <text>`.
/// Later fields can join the list (phase 2). "All 4 fields present" is phase 1's allowlist rule, not the grammar.
enum WorkflowDispatch {
    static let prefix = "Cadence stage: "
    static let reasonMarker = " reason: "

    /// The fixed skill table. Only these 5 stages can be sent.
    static func skill(_ stage: WorkflowGates.Stage) -> String { "/cadence:cad-\(stage.rawValue)" }

    enum Refusal: Error, Equatable {
        case badPhase(String)
        case badRouting(String)
        case badArgument(String)
        case badChip(String)
        case emptyReason
        case tooLong(Int)

        var message: String {
            switch self {
            case .badPhase(let text): return "Phase \"\(text)\" is not a plain number, so nothing was sent."
            case .badRouting(let text): return text
            case .badArgument: return "The argument is empty or holds a control character, so nothing was sent."
            case .badChip(let text): return text
            case .emptyReason: return "The reason is empty. Nothing was sent."
            case .tooLong(let count): return "Too long to send: \(count) of \(InboxDelivery.requestMaxLength) characters"
            }
        }
    }

    /// `^[0-9]+(\.[0-9]+)?$` on ASCII digits only.
    static func isPhaseNumber(_ phase: String) -> Bool {
        let parts = phase.split(separator: ".", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
    }

    static func line(stage: WorkflowGates.Stage, phase: String, routing: StageRouting.Entry,
                     reason: String? = nil) -> Result<String, Refusal> {
        line(skill: skill(stage), phase: phase, routing: routing, reason: reason)
    }

    /// Fields in order: skill, optional phase, optional arg, model, effort. An argument is refused, never cleaned:
    /// flattening it would change its meaning.
    static func line(skill: String, phase: String?, argument: String? = nil, routing: StageRouting.Entry,
                     reason: String? = nil) -> Result<String, Refusal> {
        if let phase, !isPhaseNumber(phase) { return .failure(.badPhase(phase)) }
        if let refusal = routing.refusal { return .failure(.badRouting(refusal)) }
        if let argument, argument.isEmpty || argument.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .failure(.badArgument(argument))
        }
        var fields = [("skill", skill)]
        if let phase { fields.append(("phase", phase)) }
        if let argument { fields.append(("arg", argument)) }
        fields += [("model", routing.model ?? "none"), ("effort", routing.effort ?? "none")]
        var text = prefix + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        if let reason {
            // The cap is passed: the default of 200 would cut a longer reason.
            guard let cleaned = InboxDelivery.clean(reason, cap: InboxDelivery.requestMaxLength) else {
                return .failure(.emptyReason)
            }
            text += reasonMarker + cleaned
        }
        let count = text.unicodeScalars.count
        return count > InboxDelivery.requestMaxLength ? .failure(.tooLong(count)) : .success(text)
    }

    /// The worker label `cad-<stage>-p<N>`, each dot of the phase text a hyphen: 1.1 gives `cad-execute-p1-1`.
    static func label(stage: WorkflowGates.Stage, phase: String) -> String {
        label(skill: skill(stage), phase: phase)
    }

    /// What a chip row takes. A row is data: the shape picks the check, no per-skill branch.
    enum Shape { case bare, phase, decisionReview, config }

    /// The 7 chip rows (D-05). Nothing outside this table can be sent by a chip or a config fix.
    static let chipTable: [(skill: String, shape: Shape)] = [
        ("/cadence:cad-audit", .bare), ("/cadence:cad-health", .bare), ("/cadence:cad-suggest", .bare),
        ("/cadence:cad-coverage", .phase), ("/cadence:cad-minimalism-review", .phase),
        ("/cadence:cad-decision-review", .decisionReview), ("/cadence:cad-config", .config),
    ]

    /// The line for a chip row. Config pairs arrive as `key=value` tokens joined by 1 space. Any bad part refuses the
    /// whole line and builds nothing (D-11).
    static func chipLine(skill: String, phase: String?, argument: String? = nil,
                         routing: StageRouting.Entry) -> Result<String, Refusal> {
        guard let shape = chipTable.first(where: { $0.skill == skill })?.shape else {
            return .failure(.badChip("\(skill) is not a board skill, so nothing was sent."))
        }
        var arg = argument
        switch shape {
        case .bare:
            guard phase == nil, argument == nil else { return .failure(.badChip("\(skill) takes no phase or argument.")) }
        case .phase:
            guard phase != nil, argument == nil else { return .failure(.badChip("\(skill) takes a phase and no argument.")) }
        case .decisionReview:
            guard let phase, isPhaseNumber(phase) else { return .failure(.badPhase(phase ?? "")) }
            guard argument == ".planning/PROJECT.md" || argument == ".planning/phases/\(phase)/CONTEXT.md" else {
                return .failure(.badChip("The decision file is not on the fixed list, so nothing was sent."))
            }
        case .config:
            guard phase == nil, let argument else { return .failure(.badChip("\(skill) takes an argument and no phase.")) }
            switch configPairs(argument) {
            case .success(let text): arg = text
            case .failure(let refusal): return .failure(refusal)
            }
        }
        return line(skill: skill, phase: phase, argument: arg, routing: routing)
    }

    /// The cad-config line for one priced pair of a run-record suggestion. The 7-pair table does not apply; the
    /// orchestrator checks the pair against a live `trace suggest`. No `--global`, no reason text.
    static func suggestionConfigLine(action: String, proposed: String, routing: StageRouting.Entry) -> Result<String, Refusal> {
        let keyScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        guard !action.isEmpty, !action.hasPrefix("--"), action.unicodeScalars.allSatisfy(keyScalars.contains) else {
            return .failure(.badChip("\"\(action)\" is not a setting key, so nothing was sent."))
        }
        let bad = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !proposed.isEmpty, !proposed.hasPrefix("--"), !proposed.unicodeScalars.contains(where: bad.contains) else {
            return .failure(.badChip("The value for \(action) is empty or not plain text, so nothing was sent."))
        }
        return line(skill: "/cadence:cad-config", phase: nil, argument: "\(action)=\(proposed)", routing: routing)
    }

    /// Each token must be a recommended key with its recommended value (D-05: that table is the allowlist). A token
    /// that starts with a double dash cannot match a key, so it is refused. Output is in table order.
    private static func configPairs(_ argument: String) -> Result<String, Refusal> {
        let tokens = argument.split(separator: " ", omittingEmptySubsequences: false)
        var picked: [(index: Int, text: String)] = []
        for token in tokens {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !token.hasPrefix("--"),
                  let index = CadenceConfigCheck.recommended.firstIndex(where: { $0.key == parts[0] }),
                  CadenceConfigCheck.recommended[index].value.text == parts[1] else {
                return .failure(.badChip("\"\(token)\" is not a recommended setting, so nothing was sent."))
            }
            picked.append((index, String(token)))
        }
        guard !picked.isEmpty else { return .failure(.badChip("No settings to fix, so nothing was sent.")) }
        return .success(picked.sorted { $0.index < $1.index }.map(\.text).joined(separator: " "))
    }

    /// `cad-<skill>-p<N>`, or `cad-<skill>` with no phase. `<skill>` is the whole text after `/cadence:cad-`.
    static func label(skill: String, phase: String?) -> String {
        let name = "cad-" + skill.replacingOccurrences(of: "/cadence:cad-", with: "")
        guard let phase else { return name }
        return name + "-p" + phase.replacingOccurrences(of: ".", with: "-")
    }
}
