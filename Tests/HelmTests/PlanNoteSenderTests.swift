import Foundation
import Testing
@testable import Helm

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, String)] = []
    var gate: DispatchSemaphore?
    var result: InboxDelivery.Outcome = .sent
    var calls: [(String, String)] { lock.lock(); defer { lock.unlock() }; return items }
    func run(_ text: String, _ inbox: String) -> InboxDelivery.Outcome {
        lock.lock(); items.append((text, inbox)); lock.unlock()
        gate?.wait()
        return result
    }
}

@MainActor @Suite struct PlanNoteSenderTests {
    private func row(_ inbox: String? = "/tmp/inbox", event: String? = "done", at: String? = "2026-01-01T00:00:00Z") -> WorkerRow {
        WorkerRow(agentId: "cad-plan-p4", status: "running", taskTitle: nil, lastEvent: event,
                  lastActivityAt: at, inboxPath: inbox)
    }
    private func sender(_ rec: Recorder, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> PlanNoteSender {
        PlanNoteSender(append: { rec.run($0, $1) }, now: { now })
    }

    @Test func onePressAppendsOnceWithBuiltMessageAndClearsText() async throws {
        let rec = Recorder(), s = sender(rec)
        s.notes = "make it shorter"
        await s.send(phase: "4", rows: [row()])
        #expect(rec.calls.count == 1)
        #expect(rec.calls[0].0 == (try PlanNoteMessage.make(phase: "4", notes: "make it shorter").get()))
        #expect(rec.calls[0].1 == "/tmp/inbox")
        #expect(s.outcome == .sent && s.notes == "")
    }

    @Test func doublePressWhileSendingAppendsOnce() async {
        let rec = Recorder(); rec.gate = DispatchSemaphore(value: 0)
        let s = sender(rec); s.notes = "x"
        let first = Task { await s.send(phase: "4", rows: [row()]) }
        while !s.sending { await Task.yield() }
        await s.send(phase: "4", rows: [row()])
        rec.gate?.signal()
        await first.value
        #expect(rec.calls.count == 1)
    }

    @Test func missingRowOrInboxRefusesWithoutAppend() async {
        let rec = Recorder(), s = sender(rec); s.notes = "x"
        await s.send(phase: "4", rows: [])
        guard case .refused? = s.outcome else { Issue.record("no refusal"); return }
        await s.send(phase: "4", rows: [row(nil)])
        guard case .refused? = s.outcome else { Issue.record("no refusal"); return }
        #expect(rec.calls.isEmpty && s.notes == "x" && !s.notesInFlight)
    }

    @Test func failedAppendKeepsTextAndNoFlag() async {
        let rec = Recorder(); rec.result = .failed("disk")
        let s = sender(rec); s.notes = "keep me"
        await s.send(phase: "4", rows: [row()])
        #expect(s.outcome == .failed("disk") && s.notes == "keep me" && !s.notesInFlight)
    }

    @Test func notesOffNeverEntersSendPath() {
        var entered = 0
        let off = PlanReviewActions.make(state: .readyWorkerEnded(reviewInFlight: false), gate: "advisory", notesInFlight: false).notes
        PlanReviewActions.pressNotes(off) { entered += 1 }
        let gateOff = PlanReviewActions.make(state: .readyForReview(reviewInFlight: false), gate: "off", notesInFlight: false).notes
        PlanReviewActions.pressNotes(gateOff) { entered += 1 }
        #expect(entered == 0)
        let on = PlanReviewActions.make(state: .readyForReview(reviewInFlight: false), gate: nil, notesInFlight: false).notes
        PlanReviewActions.pressNotes(on) { entered += 1 }
        #expect(entered == 1)
    }

    @Test func flagLifecycle() async {
        let rec = Recorder(), s = sender(rec); s.notes = "x"
        #expect(!s.notesInFlight)
        await s.send(phase: "4", rows: [row()])
        #expect(s.notesInFlight)
        s.observe(rows: [row()], phase: "4", workerGone: false)
        #expect(s.notesInFlight)
        s.observe(rows: [row(event: "busy")], phase: "4", workerGone: false)
        #expect(s.notesInFlight)
        s.observe(rows: [row(at: "2027-06-01T00:00:00Z")], phase: "4", workerGone: false)
        #expect(!s.notesInFlight)
    }

    @Test func flagClearsWhenWorkerGoneOrRowRemoved() async {
        for gone in [true, false] {
            let rec = Recorder(), s = sender(rec); s.notes = "x"
            await s.send(phase: "4", rows: [row()])
            s.observe(rows: gone ? [row()] : [], phase: "4", workerGone: gone)
            #expect(!s.notesInFlight)
        }
    }

    @Test func defaultAppendAddsOneJSONLineAndMissingInboxCreatesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = dir.appendingPathComponent("inbox.jsonl").path
        FileManager.default.createFile(atPath: inbox, contents: Data())
        let s = PlanNoteSender(); s.notes = "line1\nline2"
        await s.send(phase: "4", rows: [row(inbox)])
        let lines = try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)
        let json = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let content = (json["message"] as? [String: Any])?["content"] as? String
        #expect(content == (try PlanNoteMessage.make(phase: "4", notes: "line1\nline2").get()))

        let missing = dir.appendingPathComponent("none.jsonl").path
        let t = PlanNoteSender(); t.notes = "x"
        await t.send(phase: "4", rows: [row(missing)])
        guard case .failed? = t.outcome else { Issue.record("expected failure"); return }
        #expect(!FileManager.default.fileExists(atPath: missing))
    }
}
