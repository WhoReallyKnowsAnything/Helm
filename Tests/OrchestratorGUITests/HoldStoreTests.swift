import Foundation
import Testing
import os
@testable import OrchestratorGUI

@Suite(.serialized) @MainActor struct HoldStoreTests {
    private func make() throws -> (FixtureHolds, FixtureProject) {
        let fx = try FixtureProject.make(withDatabase: false)
        return (FixtureHolds(fx), fx)
    }

    /// The store drops the hold on the event. The 2 s bound is proved by the next test, off the main actor.
    @Test func listsTwoLiveHoldsAndDropsOneWhenItsFileIsDeleted() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "toolu_B", command: "git push origin dev", epoch: "200")
        try fixture.add(id: "toolu_A", epoch: "100")
        let store = HoldStore()
        defer { store.point(at: nil) }
        store.point(at: fx.path)
        await settle { store.holds.count == 2 }
        #expect(store.holds.map(\.id) == ["toolu_A", "toolu_B"])

        try FileManager.default.removeItem(atPath: fixture.folder + "/toolu_A.pending")
        await settle { store.holds.count == 1 }
        #expect(store.holds.map(\.id) == ["toolu_B"])
    }

    /// The 2 s proof, on the real clock. It covers the watcher and the reader (`ProjectWatcher` plus
    /// `GateHoldReader`), not `HoldStore` itself. The callback runs on the watcher's queue and the test
    /// thread waits on a semaphore, so a busy main actor adds nothing to the measured time.
    @Test nonisolated func aDeletedHoldIsMissingFromTheWatcherReadWithin2Seconds() throws {
        struct Drop { var deleteReturned = false, end: ContinuousClock.Instant? }
        let fx = try FixtureProject.make(withDatabase: false)
        let fixture = FixtureHolds(fx)
        defer { fixture.remove() }
        try fixture.add(id: "toolu_B", command: "git push origin dev", epoch: "200")
        try fixture.add(id: "toolu_A", epoch: "100")
        let drop = OSAllocatedUnfairLock(initialState: Drop())
        let dropped = DispatchSemaphore(value: 0)
        let project = fx.path
        let watcher = ProjectWatcher(holdsOf: project) {
            guard case .holds(let list) = GateHoldReader.read(project: project, isHookLive: { _, _ in true }) else { return }
            let missing = !list.contains { $0.id == "toolu_A" }
            let now = ContinuousClock.now
            // Write once: only the first read after the delete call returned that lacks the id stamps and signals.
            let stamped = drop.withLock { state -> Bool in
                guard state.deleteReturned, state.end == nil, missing else { return false }
                state.end = now
                return true
            }
            if stamped { dropped.signal() }
        }
        defer { withExtendedLifetime(watcher) {} }

        let start = ContinuousClock.now
        try FileManager.default.removeItem(atPath: fixture.folder + "/toolu_A.pending")
        drop.withLock { $0.deleteReturned = true }
        // 30 s is only a hang guard. The claim is the 2 s check below.
        try #require(dropped.wait(timeout: .now() + 30) == .success)
        let end = try #require(drop.withLock { $0.end })
        #expect(end - start < .seconds(2))
    }

    @Test func aValidDecisionFileChangesTheHoldToDecided() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        let hash = try fixture.add(id: "toolu_A")
        let store = HoldStore()
        defer { store.point(at: nil) }
        store.point(at: fx.path)
        await settle { store.holds.count == 1 }
        #expect(store.holds.first?.state == .live)
        try "allow \(hash)".write(toFile: fixture.folder + "/toolu_A.decision", atomically: false, encoding: .utf8)
        await settle { store.holds.first?.state == .decided }
        #expect(store.holds.first?.state == .decided)
    }

    @Test func aFolderCreatedAfterPointingIsPickedUp() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        let store = HoldStore()
        defer { store.point(at: nil) }
        store.point(at: fx.path)
        try await Task.sleep(for: .milliseconds(800))
        #expect(store.holds.isEmpty)
        try fixture.add(id: "toolu_A")
        await settle { store.holds.count == 1 }
        #expect(store.holds.map(\.id) == ["toolu_A"])
    }

    @Test func pointingAtAnotherFolderDropsTheOldHolds() async throws {
        let (fixture, fx) = try make()
        let (other, otherFx) = try make()
        defer { fixture.remove(); other.remove() }
        try fixture.add(id: "toolu_A")
        let store = HoldStore()
        defer { store.point(at: nil) }
        store.point(at: fx.path)
        await settle { store.holds.count == 1 }
        store.point(at: otherFx.path)
        #expect(store.holds.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.holds.isEmpty)
        store.point(at: nil)
        #expect(store.holds.isEmpty)
    }

    @Test func anUnreadableFolderSetsAFailureAndAFixClearsIt() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "toolu_A")
        chmod(fixture.folder, 0o000)
        let store = HoldStore()
        defer { store.point(at: nil) }
        store.point(at: fx.path)
        await settle { store.failure != nil }
        #expect(store.failure != nil)
        #expect(store.holds.isEmpty)
        chmod(fixture.folder, 0o755)
        store.requestRead()
        await settle { store.failure == nil && store.holds.count == 1 }
        #expect(store.failure == nil)
    }

    @Test func anUnchangedReadPublishesNothing() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "toolu_A")
        let store = HoldStore()
        defer { store.point(at: nil) }
        var sends = 0
        let sink = store.objectWillChange.sink { sends += 1 }
        defer { sink.cancel() }
        store.point(at: fx.path)
        await settle { store.holds.count == 1 }
        let after = sends
        store.requestRead()
        store.requestRead()
        try await Task.sleep(for: .milliseconds(500))
        #expect(sends == after)
    }

    // MARK: Click safety and the decide flow

    private func decideStore(_ fx: FixtureProject, _ calls: Calls) -> HoldStore {
        let store = HoldStore(decider: { calls.record($0, $1, $2, $3, $4) })
        store.point(at: fx.path)
        return store
    }

    private func call(_ choice: HoldChoice, hash: String, fx: FixtureProject, id: String = "toolu_A") -> Calls.Call {
        Calls.Call(label: "bravo", id: id, choice: choice, hash: hash, folder: fx.path)
    }

    @Test(arguments: [HoldChoice.allow, HoldChoice.deny])
    func approveAndDenyCallTheDeciderOnceWithTheDrawnValues(choice: HoldChoice) async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        let hash = try fixture.add(id: "toolu_A")
        let calls = Calls()
        let store = decideStore(fx, calls)
        defer { store.point(at: nil) }
        await settle { store.holds.count == 1 }
        let hold = try #require(store.holds.first)
        #expect(store.card(for: hold).enabled)
        store.decide(hold.key, choice)
        await settle { store.card(for: hold).outcome != nil }
        #expect(calls.all == [call(choice, hash: hash, fx: fx)])
        #expect(store.card(for: hold).outcome == "decision sent")
        #expect(!store.card(for: hold).showsButtons)
        store.decide(hold.key, choice)
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls.all.count == 1)
    }

    @Test func aClickRightAfterTheHoldAppearsCallsOnce() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        let hash = try fixture.add(id: "toolu_A")
        let calls = Calls()
        let store = decideStore(fx, calls)
        defer { store.point(at: nil) }
        await settle { store.holds.count == 1 }
        let hold = try #require(store.holds.first)
        #expect(store.card(for: hold).enabled)
        store.decide(hold.key, .allow)
        await settle { calls.all.count == 1 }
        #expect(calls.all == [call(.allow, hash: hash, fx: fx)])
    }

    @Test(arguments: [HoldChoice.allow, HoldChoice.deny])
    func aCommandOf1500CharactersIsAnsweredAtOnce(choice: HoldChoice) async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        let hash = try fixture.add(id: "toolu_A", command: String(repeating: "x", count: 1500))
        let calls = Calls()
        let store = decideStore(fx, calls)
        defer { store.point(at: nil) }
        await settle { store.holds.count == 1 }
        let hold = try #require(store.holds.first)
        #expect(store.card(for: hold).command.count == 1506)
        #expect(store.card(for: hold).enabled)
        store.decide(hold.key, choice)
        await settle { calls.all.count == 1 }
        #expect(calls.all == [call(choice, hash: hash, fx: fx)])
    }

    @Test func aSecondClickWhileTheFirstRunsCallsNothing() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "toolu_A")
        let calls = Calls()
        let store = decideStore(fx, calls)
        defer { store.point(at: nil) }
        await settle { store.holds.count == 1 }
        let hold = try #require(store.holds.first)
        let release = calls.holdNextCalls()
        store.decide(hold.key, .allow)
        await settle { calls.all.count == 1 }
        #expect(!store.card(for: hold).enabled)
        store.decide(hold.key, .deny)
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.all.count == 1)
        release.signal()
        await settle { store.card(for: hold).outcome != nil }
        #expect(store.card(for: hold).outcome == "decision sent")
    }

    @Test func aDecisionThatAppearsAfterTheHoldWasDrawnGivesNoCall() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        let hash = try fixture.add(id: "toolu_A")
        let calls = Calls()
        let store = decideStore(fx, calls)
        defer { store.point(at: nil) }
        await settle { store.holds.count == 1 }
        let hold = try #require(store.holds.first)
        // No await between the write and the click, so the store still has the hold as live.
        try "allow \(hash)".write(toFile: fixture.folder + "/toolu_A.decision", atomically: false, encoding: .utf8)
        store.decide(hold.key, .allow)
        await settle { store.card(for: hold).outcome != nil }
        #expect(store.card(for: hold).outcome == "decided")
        #expect(calls.all.isEmpty)
    }

    @Test func aHoldWhoseFilesWereDeletedOrRewrittenGivesNoCall() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "toolu_A", epoch: "100")
        try fixture.add(id: "toolu_B", command: "git commit -m wip", epoch: "200")
        let calls = Calls()
        let store = decideStore(fx, calls)
        defer { store.point(at: nil) }
        await settle { store.holds.count == 2 }
        let (first, second) = (store.holds[0], store.holds[1])
        try FileManager.default.removeItem(atPath: fixture.folder + "/toolu_A.pending")
        try fixture.add(id: "toolu_B", command: "git push origin other", epoch: "200")
        store.decide(first.key, .allow)
        store.decide(second.key, .allow)
        try await Task.sleep(for: .milliseconds(400))
        #expect(calls.all.isEmpty)
    }

    @Test func theAttemptReadsTheHoldAgainRightBeforeDeciding() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        let hash = try fixture.add(id: "toolu_A")
        let calls = Calls()
        func attempt(id: String = "toolu_A") -> HoldAttempt {
            HoldStore.attempt(
                project: fx.path, label: "bravo", id: id, choice: .allow, hash: hash,
                decider: { calls.record($0, $1, $2, $3, $4) })
        }
        #expect(attempt() == .ran(.delivered))
        #expect(calls.all.count == 1)

        try "allow \(hash)".write(toFile: fixture.folder + "/toolu_A.decision", atomically: false, encoding: .utf8)
        #expect(attempt() == .decided)
        try FileManager.default.removeItem(atPath: fixture.folder + "/toolu_A.decision")

        try fixture.add(id: "toolu_A", command: "git push origin other")
        #expect(attempt() == .stale("the hold changed"))

        let deadHash = try fixture.add(id: "toolu_D", hook: .dead)
        #expect(HoldStore.attempt(
            project: fx.path, label: "bravo", id: "toolu_D", choice: .allow, hash: deadHash,
            decider: { calls.record($0, $1, $2, $3, $4) }) == .stale("hook ended"))

        try FileManager.default.removeItem(atPath: fixture.folder + "/toolu_A.pending")
        #expect(attempt() == .gone)
        #expect(calls.all.count == 1)
    }

    @Test func theAttemptOutcomesGiveTheCardText() {
        #expect(HoldAttempt.gone.outcome.text == "already decided or ended")
        #expect(HoldAttempt.gone.outcome.final)
        #expect(HoldAttempt.decided.outcome.text == "decided")
        #expect(HoldAttempt.ran(.alreadyDecided).outcome.text == "already decided or ended")
        #expect(HoldAttempt.ran(.delivered).outcome.text == "decision sent")
        #expect(HoldAttempt.ran(.delivered).outcome.final)
        #expect(HoldAttempt.ran(.failed("boom")).outcome.text == "boom")
        #expect(!HoldAttempt.ran(.failed("boom")).outcome.final)
    }

    @Test func theNoLongerWaitingRefusalRemovesTheButtons() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "toolu_A")
        let calls = Calls()
        calls.answer(.alreadyDecided)
        let store = decideStore(fx, calls)
        defer { store.point(at: nil) }
        await settle { store.holds.count == 1 }
        let hold = try #require(store.holds.first)
        store.decide(hold.key, .deny)
        await settle { store.card(for: hold).outcome != nil }
        #expect(store.card(for: hold).outcome == "already decided or ended")
        #expect(!store.card(for: hold).showsButtons)
    }

    @Test func anotherErrorShowsItsLineAndEnablesThePairAgain() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "toolu_A")
        let calls = Calls()
        calls.answer(.failed("Error: --gate-decide refused: bad op hash"))
        let store = decideStore(fx, calls)
        defer { store.point(at: nil) }
        await settle { store.holds.count == 1 }
        let hold = try #require(store.holds.first)
        store.decide(hold.key, .allow)
        await settle { store.card(for: hold).outcome != nil }
        #expect(store.card(for: hold).outcome == "Error: --gate-decide refused: bad op hash")
        #expect(store.card(for: hold).showsButtons)
        #expect(store.card(for: hold).enabled)

        calls.answer(.delivered)
        store.decide(hold.key, .allow)
        await settle { store.card(for: hold).outcome == "decision sent" }
        #expect(store.card(for: hold).outcome == "decision sent")
        #expect(calls.all.count == 2)
    }

    @Test func decidedDeadTamperedAndMalformedDecisionHoldsAreNeverAnswerable() async throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "toolu_1", decision: { "allow \($0)" })
        try fixture.add(id: "toolu_2", hook: .dead)
        try fixture.add(id: "toolu_3", altered: "git push origin evil")
        try fixture.add(id: "toolu_4", decision: { _ in "junk" })
        let calls = Calls()
        let store = decideStore(fx, calls)
        defer { store.point(at: nil) }
        await settle { store.holds.count == 4 }
        let byId = Dictionary(uniqueKeysWithValues: store.holds.map { ($0.id, $0) })
        let lines = ["toolu_1": "decided", "toolu_2": "hook ended", "toolu_3": "tampered hold"]
        for (id, line) in lines {
            let hold = try #require(byId[id])
            #expect(store.card(for: hold).stateLine == line)
            #expect(!store.card(for: hold).showsButtons)
            #expect(!store.card(for: hold).enabled)
            store.decide(hold.key, .allow)
        }
        let malformed = try #require(byId["toolu_4"])
        #expect(store.card(for: malformed).stateLine == nil)
        #expect(store.card(for: malformed).showsButtons)
        #expect(store.card(for: malformed).enabled)
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.all.isEmpty)
    }
}

/// A decider that records its calls. `holdNextCalls` makes every call wait until the returned semaphore is signalled.
private final class Calls: @unchecked Sendable {
    struct Call: Equatable {
        let label: String
        let id: String
        let choice: HoldChoice
        let hash: String
        let folder: String
    }

    private let lock = NSLock()
    private var list: [Call] = []
    private var reply: HoldDecision = .delivered
    private var gate: DispatchSemaphore?

    var all: [Call] { lock.lock(); defer { lock.unlock() }; return list }

    func answer(_ decision: HoldDecision) { lock.lock(); reply = decision; lock.unlock() }

    func holdNextCalls() -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock(); gate = semaphore; lock.unlock()
        return semaphore
    }

    func record(_ label: String, _ id: String, _ choice: HoldChoice, _ hash: String, _ folder: String) -> HoldDecision {
        lock.lock()
        list.append(Call(label: label, id: id, choice: choice, hash: hash, folder: folder))
        let answer = reply, wait = gate
        lock.unlock()
        wait?.wait()
        return answer
    }
}
