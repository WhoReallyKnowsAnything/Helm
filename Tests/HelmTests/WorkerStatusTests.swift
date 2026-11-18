import Foundation
import Testing
@testable import Helm

struct WorkerStatusTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(status: String, last: String? = nil) -> WorkerRow {
        WorkerRow(agentId: "w", status: status, taskTitle: nil, lastEvent: last)
    }

    private func status(_ row: WorkerRow, _ secondsAgo: Double? = nil) -> WorkerStatus? {
        WorkerStatusRules.status(of: row, lastWrite: secondsAgo.map { now.addingTimeInterval(-$0) }, now: now)
    }

    @Test func fixtureRowsGiveRunningWaitingFinishedAndHideDelta() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        guard case .loaded(let loaded) = WorkerDatabase(project: fx.path).read() else { Issue.record("not loaded"); return }
        let shown = loaded.rows.map { ($0.agentId, status($0)) }
        #expect(shown.map(\.0) == ["alpha", "bravo", "charlie", "delta"])
        #expect(shown.map(\.1) == [.running, .waiting, .finished, nil])
    }

    @Test func deadIsHidden() { #expect(status(row(status: "dead")) == nil) }

    @Test func lastEventBlockedWithStatusRunningWaits() {
        #expect(status(row(status: "running", last: "blocked")) == .waiting)
    }

    @Test func stallNeedsMoreThanTenMinutes() {
        #expect(status(row(status: "running"), 599) == .running)
        #expect(status(row(status: "running"), 600) == .running)
        #expect(status(row(status: "running"), 601) == .stalled)
    }

    @Test func silentBlockedAndFinishedWorkersKeepTheirStatus() {
        #expect(status(row(status: "blocked"), 1800) == .waiting)
        #expect(status(row(status: "running", last: "done"), 1800) == .finished)
        #expect(status(row(status: "done"), 1800) == .finished)
    }

    @Test func rawStalledIsStalled() { #expect(status(row(status: "stalled")) == .stalled) }

    @Test func noLogIsNeverStalled() { #expect(status(row(status: "running"), nil) == .running) }

    private func created(secondsAgo: Double) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format.string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func gone(_ status: String, last: String? = nil, createdAgo: Double? = 100) -> WorkerStatus? {
        var r = row(status: status, last: last)
        r.createdAt = createdAgo.map { created(secondsAgo: $0) }
        return WorkerStatusRules.status(of: r, lastWrite: nil, now: now, live: false)
    }

    @Test func runningBlockedAndStalledRowsWithNoProcessReadDead() {
        #expect(gone("running") == .dead)
        #expect(gone("blocked") == .dead)
        #expect(gone("stalled") == .dead)
        #expect(gone("running", last: "blocked") == .dead)
        #expect(gone("running", createdAgo: nil) == .dead)
    }

    @Test func aRowInsideTheStartingWindowReadsAsBefore() {
        #expect(gone("running", createdAgo: 3) == .running)
        #expect(gone("blocked", createdAgo: 3) == .waiting)
    }

    @Test func unknownLivenessReadsAsBefore() {
        var r = row(status: "running")
        r.createdAt = created(secondsAgo: 100)
        #expect(WorkerStatusRules.status(of: r, lastWrite: nil, now: now) == .running)
        #expect(WorkerStatusRules.status(of: r, lastWrite: nil, now: now, live: true) == .running)
    }

    @Test func aFinishedRowWithNoProcessStaysFinished() {
        #expect(gone("done") == .finished)
        #expect(gone("running", last: "done") == .finished)
        #expect(gone("merged") == nil)
    }

    @Test func limitedStateWithoutLastEvent() {
        #expect(status(row(status: "blocked", last: nil)) == .waiting)
        #expect(status(row(status: "running", last: nil)) == .running)
    }
}
