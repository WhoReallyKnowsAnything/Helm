import Foundation

/// State of the pick-up flow (D-08). The delivery arrives as a closure, so tests use a stub and the blocking
/// call runs off the main actor. One pick at a time: a double click delivers once.
@MainActor
final class DispatchModel: ObservableObject {
    static let linePrefix = "Pick up the Notion task: "

    @Published private(set) var isSending = false
    /// Why the last pick sent nothing, or nil. The sheet stays open.
    @Published private(set) var message: String?
    /// True after a pick was sent; the view closes the sheet and selects the orchestrator node.
    @Published private(set) var sent = false

    private let deliver: @Sendable (_ line: String) -> InboxDelivery.Outcome

    init(deliver: @escaping @Sendable (_ line: String) -> InboxDelivery.Outcome) {
        self.deliver = deliver
    }

    func pick(title: String) async {
        await submit(title, prefix: Self.linePrefix, cap: InboxDelivery.maxLength, refusesOverCap: false,
                     emptyMessage: "The task title is empty. Nothing was sent.")
    }

    /// The Dispatch bar (D-13a point 2). Empty text opens the sheet. Other text goes through the same delivery as a pick, typed
    /// plain with no prefix, because the orchestrator reads plain language as new work. Text over the cap is refused, never cut:
    /// the host clears the field only when `sent` turns true, so a refused request stays to be shortened.
    func sendRequest(_ text: String, openSheet: () -> Void) async {
        guard !isSending else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = nil
            openSheet()
            return
        }
        await submit(text, prefix: "", cap: InboxDelivery.requestMaxLength, refusesOverCap: true,
                     emptyMessage: "The text is empty. Nothing was sent.")
    }

    /// The board's next-step button: sends an already-built line, no prefix, over the 2000 cap refused, one send at a time.
    func sendLine(_ line: String) async {
        await submit(line, prefix: "", cap: InboxDelivery.requestMaxLength, refusesOverCap: true,
                     emptyMessage: "The line is empty. Nothing was sent.")
    }

    private func submit(_ text: String, prefix: String, cap: Int, refusesOverCap: Bool, emptyMessage: String) async {
        guard !isSending else { return }
        message = nil
        sent = false
        // Scalars, not Characters: a CRLF pair is one Character but `clean` turns it into 2 spaces.
        let count = text.unicodeScalars.count
        if refusesOverCap, count > cap {
            message = "Too long to send: \(count) of \(cap) characters"
            return
        }
        guard let cleaned = InboxDelivery.clean(text, cap: cap) else {
            message = emptyMessage
            return
        }
        isSending = true
        defer { isSending = false }
        let deliver = self.deliver, line = prefix + cleaned
        switch await Task.detached(operation: { deliver(line) }).value {
        case .sent: sent = true
        case .refused(let text), .failed(let text): message = text
        }
    }
}
