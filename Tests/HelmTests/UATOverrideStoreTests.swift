import Foundation
import Testing
@testable import Helm

private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    private let gate = DispatchSemaphore(value: 0)
    var blocking = false
    func add(_ m: String) {
        lock.lock(); messages.append(m); lock.unlock()
        if blocking { gate.wait() }
    }
    func release() { gate.signal() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return messages }
}

private final class Fired: @unchecked Sendable {
    var labels: [String] = []
}

@MainActor @Suite(.serialized) struct UATOverrideStoreTests {
    private let label = "cad-verify-p3"

    private func row(stamp: String?, event: String? = "done", label: String = "cad-verify-p3") -> WorkerRow {
        WorkerRow(agentId: label, status: "running", taskTitle: nil, lastEvent: event, lastActivityAt: stamp, inboxPath: "/tmp/in")
    }

    private func make(_ sent: Sent) -> (UATOverrideStore, Fired) {
        let store = UATOverrideStore(deliver: { message, _ in sent.add(message); return .sent })
        let fired = Fired()
        store.onGranted = { fired.labels.append($0) }
        return (store, fired)
    }

    private func start(_ store: UATOverrideStore, reason: String = "no time") async {
        await store.send(reason: reason, row: row(stamp: "t1"), eligibility: .on, phase: "3")?.value
    }

    @Test func oneSendDeliversOneMessageAndASecondWhileBlockedDeliversNone() async {
        let sent = Sent()
        sent.blocking = true
        let (store, _) = make(sent)
        let first = store.send(reason: "no time", row: row(stamp: "t1"), eligibility: .on, phase: "3")
        #expect(store.send(reason: "again", row: row(stamp: "t1"), eligibility: .on, phase: "3") == nil)
        sent.release()
        await first?.value
        #expect(sent.all.count == 1 && store.state == .waiting)
    }

    @Test func aRefusedEligibilityDeliversNothing() {
        let sent = Sent()
        let (store, _) = make(sent)
        #expect(store.send(reason: "x", row: row(stamp: "t1"), eligibility: .off("worker ended: a capture needs a live worker"), phase: "3") == nil)
        #expect(sent.all.isEmpty && store.state == .refused("worker ended: a capture needs a live worker"))
    }

    @Test func waitsForAFreshDoneMarkThenGrantsOnce() async {
        let (store, fired) = make(Sent())
        await start(store)
        store.rowsChanged([row(stamp: "t1")], live: [label])
        #expect(store.state == .waiting)
        store.rowsChanged([row(stamp: "t2", event: nil)], live: [label])
        #expect(store.state == .waiting)
        store.rowsChanged([row(stamp: "t2")], live: [label])
        #expect(store.state == .granted && store.granted == [label] && fired.labels == [label])
        store.rowsChanged([row(stamp: "t3")], live: [label])
        #expect(store.state == .granted && fired.labels.count == 1)
    }

    @Test func removingTheRowDropsTheGrant() async {
        let (store, _) = make(Sent())
        await start(store)
        store.rowsChanged([row(stamp: "t2")], live: [label])
        store.rowsChanged([], live: [label])
        #expect(store.granted.isEmpty && store.state == .idle)
    }

    @Test func theLabelLeavingTheLiveSetWhileWaitingRefuses() async {
        let (store, _) = make(Sent())
        await start(store)
        store.rowsChanged([row(stamp: "t1")], live: [])
        #expect(store.state == .refused("worker ended before it marked done again"))
    }

    @Test func cancelGivesIdle() async {
        let (store, _) = make(Sent())
        await start(store)
        store.cancel()
        #expect(store.state == .idle)
    }

    @Test func theReasonIsOnlyInTheDeliveredMessage() async {
        let sent = Sent()
        let (store, _) = make(sent)
        await start(store, reason: "SECRET-REASON")
        #expect(sent.all.count == 1 && sent.all[0].hasSuffix("SECRET-REASON"))
        let mirror = Mirror(reflecting: store)
        #expect(!mirror.children.contains { "\($0.value)".contains("SECRET-REASON") })
    }
}
