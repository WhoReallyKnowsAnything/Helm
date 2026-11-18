import Foundation

/// D-05: for a worker with an open pull request the app only asks the orchestrator to merge it. This model types one
/// request line into the orchestrator pane and nothing else: it never calls `MergeReview` and never runs `--merge`.
@MainActor
final class PRMergeRequest: ObservableObject {
    enum State: Equatable {
        case idle
        case sending
        case sent(String)
        /// Nothing was typed, or the typing failed. The text says why.
        case refused(String)
    }

    @Published private(set) var state = State.idle

    private let deliver: @Sendable (_ line: String, _ base: String) -> InboxDelivery.Outcome

    init(deliver: @escaping @Sendable (String, String) -> InboxDelivery.Outcome = { InboxDelivery.deliver($0, base: $1) }) {
        self.deliver = deliver
    }

    /// `Please merge PR #<number> of worker <label> (task: <title>)`. The orchestrator reads it as a plain request.
    /// The label and the title are untrusted text (D-10), so the title is cleaned and the label must be a valid one.
    /// Nil for a label that could not be typed safely.
    nonisolated static func line(number: Int, label: String, title: String?) -> String? {
        guard MergeReview.isValidLabel(label) else { return nil }
        var line = "Please merge PR #\(number) of worker \(label)"
        if let title, let cleaned = InboxDelivery.clean(title) { line += " (task: \(cleaned))" }
        return line
    }

    /// Delivers the request once, off the main actor. A second call while one is sending does nothing.
    func send(number: Int, label: String, title: String?, base: String) async {
        guard state != .sending else { return }
        guard let line = Self.line(number: number, label: label, title: title) else {
            state = .refused("The worker label cannot be typed safely. Nothing was sent.")
            return
        }
        state = .sending
        let deliver = self.deliver
        switch await Task.detached(operation: { deliver(line, base) }).value {
        case .sent: state = .sent("Request sent: \(line)")
        case .refused(let reason), .failed(let reason): state = .refused("Request not sent: \(reason)")
        }
    }

    /// Back to idle, e.g. when another worker is selected, so an old result never sits under a new worker.
    func reset() {
        if state != .sending { state = .idle }
    }
}
