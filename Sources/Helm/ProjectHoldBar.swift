import SwiftUI

/// What the bar above every project terminal lists: per worker (the window name), its gate holds and its pending requests.
/// Nil when nothing is pending. A root session lists its requests but never gate holds (D-17). The stores are already per project, so no other project's data reaches it.
struct ProjectHoldBar {
    struct Entry {
        let worker: String
        let holds: [GateHold]
        var requests: [RequestStore.Entry] = []
    }

    let entries: [Entry]

    init?(holds: [GateHold], requests: [RequestStore.Entry] = [], root: Bool) {
        let holds = root ? [] : holds
        let workers = Set(holds.map(\.label)).union(requests.map(\.nodeKey)).sorted()
        guard !workers.isEmpty else { return nil }
        entries = workers.map { worker in
            Entry(worker: worker, holds: holds.filter { $0.label == worker },
                  requests: requests.filter { $0.nodeKey == worker })
        }
    }
}

/// The bounded bar above the pane. It draws the shared cards, so a click decides only the hold or request of its own card.
struct ProjectHoldBarView: View {
    let bar: ProjectHoldBar
    let card: (GateHold) -> HoldStore.Card
    let onDecide: (_ key: String, _ choice: HoldChoice) -> Void
    var requestCard: (RequestStore.Entry) -> RequestStore.Card = { _ in
        RequestStore.Card(command: "", stateLine: nil, outcome: nil, showsButtons: false, enabled: false)
    }
    var onRequestAnswer: (_ key: String, _ allow: Bool, _ source: RequestStore.DenySource) -> Void = { _, _, _ in }
    var questionBinding = QuestionBinding.none
    var requestStamp = 0
    /// Escape on a focused request card interrupts the node's session (D-08). Nil draws cards that ignore Escape.
    var onRequestEscape: ((_ worker: String) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(bar.entries, id: \.worker) { entry in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(verbatim: entry.worker).kitType(.section).foregroundStyle(Ink.textSecondary)
                        if !entry.holds.isEmpty {
                            HoldCards(holds: entry.holds, card: card, onDecide: onDecide)
                        }
                        if !entry.requests.isEmpty {
                            RequestCards(entries: entry.requests, card: requestCard, onAnswer: onRequestAnswer,
                                         question: questionBinding, stamp: requestStamp,
                                         onEscape: onRequestEscape.map { escape in { escape(entry.worker) } })
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.sm)
        }
        .frame(maxHeight: Metric.opTextMaxHeight * 2)
        .fixedSize(horizontal: false, vertical: true)
    }
}
