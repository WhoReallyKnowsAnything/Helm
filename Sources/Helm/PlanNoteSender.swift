import Foundation

/// Sends one Notes message into the waiting plan worker's inbox (D-02). One append per accepted press; it writes no other file.
@MainActor final class PlanNoteSender: ObservableObject {
    typealias Append = @Sendable (_ text: String, _ inbox: String) -> InboxDelivery.Outcome

    @Published var notes = ""
    @Published private(set) var outcome: InboxDelivery.Outcome?
    @Published private(set) var sending = false
    /// In memory only. True from a successful send until the worker marks done again or is gone.
    @Published private(set) var notesInFlight = false

    private let append: Append
    private let now: () -> Date
    private var sentAt: Date?
    private var activityAtSend: String?

    init(append: @escaping Append = { InboxDelivery.append($0, inbox: $1) }, now: @escaping () -> Date = Date.init) {
        self.append = append
        self.now = now
    }

    func send(phase: String, rows: [WorkerRow]) async {
        guard !sending else { return }
        let text: String
        switch PlanNoteMessage.make(phase: phase, notes: notes) {
        case .failure(.badPhase): outcome = .refused("The phase text is not valid. Nothing was sent."); return
        case .failure(.emptyNotes): outcome = .refused("The notes are empty. Nothing was sent."); return
        case .success(let built): text = built
        }
        let label = WorkflowDispatch.label(stage: .plan, phase: phase)
        guard let row = rows.last(where: { $0.agentId == label }) else {
            outcome = .refused("No worker \(label) is listed. Nothing was sent."); return
        }
        guard let inbox = row.inboxPath, !inbox.isEmpty else {
            outcome = .refused("No inbox path is stored for \(label). Nothing was sent."); return
        }
        sending = true
        let append = self.append
        let result = await Task.detached { append(text, inbox) }.value
        sending = false
        outcome = result
        if result == .sent {
            notes = ""
            notesInFlight = true
            sentAt = now()
            activityAtSend = row.lastActivityAt
        }
    }

    /// Call on every rows or overlay change. `workerGone`: the overlay is dead or the row is removed.
    func observe(rows: [WorkerRow], phase: String, workerGone: Bool) {
        guard notesInFlight else { return }
        let label = WorkflowDispatch.label(stage: .plan, phase: phase)
        guard !workerGone, let row = rows.last(where: { $0.agentId == label }) else { clearFlag(); return }
        if row.lastEvent == "done", isNewer(row.lastActivityAt) { clearFlag() }
    }

    private func clearFlag() {
        notesInFlight = false
        sentAt = nil
        activityAtSend = nil
    }

    /// A done mark counts only when stamped after the send. An unreadable stamp counts when it differs from the one at send.
    private func isNewer(_ stamp: String?) -> Bool {
        guard let stamp, let sentAt else { return false }
        if let date = Self.parse(stamp) { return date > sentAt }
        return stamp != activityAtSend
    }

    private static func parse(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "UTC")
        plain.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return plain.date(from: text)
    }
}
