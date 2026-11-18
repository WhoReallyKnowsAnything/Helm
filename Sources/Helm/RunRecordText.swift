import Foundation

/// The words the run-record screen draws, built from the store's result. Pure: no UI imports. Every figure is the
/// seam's own text; the only arithmetic is the per-role `ms` sum done in `RunRecordRender` (D-01, D-04).
struct RunRecordText: Equatable {
    struct Option: Equatable {
        /// nil is the whole record.
        var phase: String?
        var label: String
    }

    struct RoleRow: Equatable {
        var name: String
        var figures: String
        var wallClock: String
        var dispatchRows: [String]
    }

    struct Tweak: Equatable {
        var number: Int
        var subject: String
        var action: String
        var current: String
        var direction: String
        var proposed: String
        var evidence: String
        /// A button is offered only when the seam priced a target.
        var priced: Bool
        /// The pair a priced tweak's button sends.
        var pair: (action: String, proposed: String)?

        static func == (a: Tweak, b: Tweak) -> Bool {
            a.number == b.number && a.subject == b.subject && a.action == b.action && a.current == b.current
                && a.direction == b.direction && a.proposed == b.proposed && a.evidence == b.evidence
                && a.priced == b.priced && a.pair?.action == b.pair?.action && a.pair?.proposed == b.pair?.proposed
        }
    }

    static let notGiven = "not given"
    static let noTarget = "no target priced"
    static let olderCycleNote = "A phase number can include an older cycle's phase with the same number."

    var scopeLine: String?
    var roles: [RoleRow] = []
    var tweaks: [Tweak] = []
    var receipts: [String] = []
    var emptyLine: String?
    var reasons: [String] = []

    static func options(rows: [WorkflowBoard.Row]) -> [Option] {
        [Option(phase: nil, label: "Whole record")] + rows.map { Option(phase: $0.n, label: "\($0.n)  \($0.name)") }
    }

    static func make(phase: String?, result: RunRecordResult?) -> RunRecordText {
        guard let result else { return RunRecordText() }
        guard let render = result.render, let suggest = result.suggest else {
            return RunRecordText(reasons: result.reasons.isEmpty ? ["The run record could not be read."] : result.reasons)
        }
        var scope = ["file: \(render.file)", "scope: \(suggest.scope ?? "whole record")"]
        if phase != nil { scope.append(olderCycleNote) }
        for (key, value) in [("capped", render.capped), ("rotated", render.rotated),
                             ("malformed", render.malformed), ("warnings", render.warnings)] {
            if let value { scope.append("\(key): \(value)") }
        }
        let roles = render.roles.map { role -> RoleRow in
            let figures = [("dispatches", role.dispatches), ("tokens", role.tokens), ("turns", role.turns),
                           ("unrecorded", role.unrecorded), ("turns_unrecorded", role.turnsUnrecorded)]
                .map { "\($0.0) \($0.1 ?? notGiven)" }.joined(separator: "  ")
            let rows = render.dispatches(of: role.name).map {
                "\($0.plan)  \($0.event)  ms \($0.ms ?? notGiven)  tokens \($0.tokens ?? notGiven)  turns \($0.turns ?? notGiven)"
            }
            return RoleRow(name: role.name, figures: figures,
                           wallClock: "wall clock \(role.wallMs) ms (sum of \(role.wallCount) dispatches)", dispatchRows: rows)
        }
        let tweaks = suggest.tweaks.enumerated().map { index, entry in
            Tweak(number: index + 1, subject: entry.subject, action: entry.action ?? notGiven,
                  current: entry.current ?? notGiven, direction: entry.direction ?? notGiven,
                  proposed: entry.proposed ?? noTarget, evidence: entry.evidence, priced: entry.isPriced,
                  pair: entry.isPriced ? (entry.action ?? "", entry.proposed ?? "") : nil)
        }
        let receipts = suggest.receipts.map { "\($0.subject): \($0.evidence)" }
        let empty = suggest.tweaks.isEmpty
            ? (suggest.eventsRead == 0 ? "no events in scope" : "\(suggest.eventsRead) events read, none cleared the floors") : nil
        return RunRecordText(scopeLine: scope.joined(separator: "  |  "), roles: roles, tweaks: tweaks,
                             receipts: receipts, emptyLine: empty)
    }
}
