import Foundation
import Testing
@testable import OrchestratorGUI

/// A stub lookup that counts its calls and can wait on a gate until the test opens it.
private final class Stub: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let gate = DispatchSemaphore(value: 0)
    private let gated: Bool
    private let result: PullRequestLookupResult

    init(_ result: PullRequestLookupResult, gated: Bool = false) {
        self.result = result
        self.gated = gated
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func open(times: Int = 1) { for _ in 0..<times { gate.signal() } }

    var lookup: PullRequestStore.Lookup {
        { [self] in
            lock.lock(); _calls += 1; lock.unlock()
            if gated { gate.wait() }
            return result
        }
    }
}

private func pr(_ number: Int) -> PullRequest {
    PullRequest(
        number: number, url: "", state: "OPEN", isDraft: false, reviewDecision: "", title: "t",
        checks: ChecksSummary(), files: [], changedFiles: 0)
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PullRequestStoreTests {
    /// No wall-clock deadline: a busy main actor must not fail the test. The suite time limit is
    /// the hang guard, and the throwing sleep lets it cancel this loop.
    private func settle(_ store: PullRequestStore, until done: (PullRequestStore.State) -> Bool) async throws {
        while !done(store.state) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func notLoading(_ state: PullRequestStore.State) -> Bool { state != .loading }

    @Test func startsUnselected() {
        #expect(PullRequestStore().state == .unselected)
    }

    @Test func selectingAWorkerRunsOneLookupAndShowsLoadingFirst() async throws {
        let store = PullRequestStore(), a = Stub(.found(pr(1)), gated: true)
        store.select(lookup: a.lookup)
        #expect(store.state == .loading)
        a.open()
        try await settle(store, until: notLoading)
        #expect(store.state == .loaded(pr(1)))
        #expect(a.calls == 1)
    }

    @Test func noPullRequestIsLoadedWithNothing() async throws {
        let store = PullRequestStore(), a = Stub(.noPullRequest)
        store.select(lookup: a.lookup)
        try await settle(store, until: notLoading)
        #expect(store.state == .loaded(nil))
    }

    @Test func aFailureShowsAsFailedWithItsText() async throws {
        let store = PullRequestStore(), a = Stub(.failed("gh: not logged in"))
        store.select(lookup: a.lookup)
        try await settle(store, until: notLoading)
        #expect(store.state == .failed("gh: not logged in"))
    }

    @Test func selectingBWhileAIsRunningDropsAsResult() async throws {
        let store = PullRequestStore(), a = Stub(.found(pr(1)), gated: true), b = Stub(.found(pr(2)))
        store.select(lookup: a.lookup)
        store.select(lookup: b.lookup)
        try await settle(store, until: notLoading)
        #expect(store.state == .loaded(pr(2)))
        a.open()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.state == .loaded(pr(2)))
        #expect(a.calls == 1 && b.calls == 1)
    }

    @Test func aNewSelectionShowsLoadingUntilItsOwnResultNotAsResult() async throws {
        let store = PullRequestStore(), a = Stub(.found(pr(1)), gated: true), b = Stub(.found(pr(2)), gated: true)
        store.select(lookup: a.lookup)
        store.select(lookup: b.lookup)
        a.open()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.state == .loading)
        b.open()
        try await settle(store, until: notLoading)
        #expect(store.state == .loaded(pr(2)))
    }

    @Test func refreshRunsOneMoreLookup() async throws {
        let store = PullRequestStore(), a = Stub(.found(pr(1)))
        store.select(lookup: a.lookup)
        try await settle(store, until: notLoading)
        store.refresh()
        #expect(store.state == .loading)
        try await settle(store, until: notLoading)
        #expect(a.calls == 2)
    }

    @Test func refreshesDuringARunningLookupMergeIntoOneFollowUp() async throws {
        let store = PullRequestStore(), a = Stub(.found(pr(1)), gated: true)
        store.select(lookup: a.lookup)
        store.refresh(); store.refresh(); store.refresh()
        a.open(times: 5)
        try await settle(store, until: notLoading)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(a.calls == 2)
        #expect(store.state == .loaded(pr(1)))
    }

    @Test func waitingWithNoRequestMakesNoCall() async throws {
        let store = PullRequestStore(), a = Stub(.found(pr(1)))
        store.select(lookup: a.lookup)
        try await settle(store, until: notLoading)
        try? await Task.sleep(for: .seconds(1.5))
        #expect(a.calls == 1)
    }

    @Test func refreshWithNothingSelectedDoesNothing() {
        let store = PullRequestStore()
        store.refresh()
        #expect(store.state == .unselected)
    }

    @Test func clearReturnsToUnselectedAndDropsALateResult() async throws {
        let store = PullRequestStore(), a = Stub(.found(pr(1)), gated: true)
        store.select(lookup: a.lookup)
        store.clear()
        #expect(store.state == .unselected)
        a.open()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.state == .unselected)
        store.refresh()
        #expect(store.state == .unselected)
        #expect(a.calls == 1)
    }
}
