import Foundation

/// Which nodes are active and which tree lines animate (D-05). It reads no clock: the caller passes `now`.
enum ActiveLines {
    /// A running node is active while its out log was written no more than this many seconds ago.
    /// 30 s is well above the 2 s poll, so lines do not flicker, and far below `WorkerStatusRules.stallSeconds`.
    /// If lines stop moving during a long quiet tool call, change this one constant.
    static let activeSeconds = 30

    struct Result: Equatable {
        let nodes: Set<String>
        let edges: [WorkerTreeEdge]
    }

    /// The orchestrator has no `WorkerStatus`, so only the write test applies to it. `waiting`, `finished` and
    /// `stalled` are never active, and a node with no log is never active (D-08). An edge animates when either end is active.
    static func resolve(nodes: [WorkerTreeNode], edges: [WorkerTreeEdge], log: [String: SessionStatusStore.Entry],
                        now: Date) -> Result {
        let active = Set(nodes.filter { node in
            guard node.status == nil || node.status == .running, let modified = log[node.key]?.modified else { return false }
            return now.timeIntervalSince(modified) <= Double(activeSeconds)
        }.map(\.key))
        return Result(nodes: active, edges: edges.filter { active.contains($0.from) || active.contains($0.to) })
    }

    /// How far along a dash cycle of `cycle` points the pattern is at `date`, repeating every `period` seconds.
    static func dashPhase(at date: Date, period: TimeInterval, cycle: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period) * cycle
    }
}
