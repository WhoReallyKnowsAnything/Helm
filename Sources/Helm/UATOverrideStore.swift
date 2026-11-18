import Foundation

/// G3 override flow (D-09): send the capture message, then wait for the worker's fresh done mark. No timer: the wait
/// ends on a row update. The reason is passed to the builder and delivery only, never stored. The grant is by label,
/// in memory, and dropped when that label has no row.
@MainActor
final class UATOverrideStore: ObservableObject {
    enum State: Equatable {
        case idle, sending, waiting, granted
        case refused(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var granted: Set<String> = []
    /// The label the current flow belongs to, so a view draws the state only for that worker.
    private(set) var label: String?
    /// Fires once per grant: merge-review may open for that label.
    var onGranted: (String) -> Void = { _ in }

    private var stampAtSend: String?
    private let deliver: @Sendable (String, String) -> InboxDelivery.Outcome

    init(deliver: @escaping @Sendable (String, String) -> InboxDelivery.Outcome = { InboxDelivery.append($0, inbox: $1) }) {
        self.deliver = deliver
    }

    /// Delivers nothing while a send is in flight or the app waits. The returned task is for tests.
    @discardableResult
    func send(reason: String, row: WorkerRow, eligibility: UATOverride.Display, phase: String) -> Task<Void, Never>? {
        if state == .sending || state == .waiting { return nil }
        switch eligibility {
        case .hidden: state = .refused("Override is not available."); return nil
        case .off(let why): state = .refused(why); return nil
        case .on: break
        }
        guard let inbox = row.inboxPath else { state = .refused("no inbox for this worker"); return nil }
        switch UATOverride.build(phase: phase, reason: reason) {
        case .refused(let why):
            state = .refused(why)
            return nil
        case .message(let message):
            label = row.agentId
            stampAtSend = row.lastActivityAt
            state = .sending
            let deliver = deliver
            return Task { [weak self] in
                let result = await Task.detached { deliver(message, inbox) }.value
                self?.sent(result)
            }
        }
    }

    private func sent(_ result: InboxDelivery.Outcome) {
        guard state == .sending else { return }
        switch result {
        case .sent: state = .waiting
        case .refused(let why), .failed(let why): state = .refused(why)
        }
    }

    /// Leaves waiting or a refusal. A send in flight cannot be cancelled.
    func cancel() {
        guard state != .sending else { return }
        state = .idle
        label = nil
        stampAtSend = nil
    }

    /// Called on each row update. `live` is nil when liveness is unknown, which keeps the wait going.
    func rowsChanged(_ rows: [WorkerRow], live: Set<String>?) {
        let present = Set(rows.map(\.agentId))
        let kept = granted.intersection(present)
        if kept != granted {
            granted = kept
            if state == .granted, let label, !kept.contains(label) { state = .idle; self.label = nil }
        }
        guard state == .waiting, let label else { return }
        if let row = rows.first(where: { $0.agentId == label }), MergeModel.isFinished(row), row.lastActivityAt != stampAtSend {
            granted.insert(label)
            state = .granted
            onGranted(label)
        } else if let live, !live.contains(label) {
            state = .refused("worker ended before it marked done again")
        }
    }
}
