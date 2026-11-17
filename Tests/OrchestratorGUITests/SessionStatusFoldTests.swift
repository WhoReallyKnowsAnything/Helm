import Foundation
import Testing
@testable import OrchestratorGUI

struct SessionStatusFoldTests {
    private func fold(_ fixture: String) throws -> SessionStatusFold {
        var fold = SessionStatusFold()
        fold.feed(try ConversationFixtures.lines(fixture))
        return fold
    }

    @Test func anEmptyFoldHasNoTurnState() {
        #expect(SessionStatusFold().turnInProgress == nil)
    }

    @Test func aTurnWithoutAResultIsInProgress() throws {
        #expect(try fold("turn-mid").turnInProgress == true)
    }

    @Test func aResultEndsTheTurn() throws {
        #expect(try fold("turn-done").turnInProgress == false)
    }

    @Test func anInterruptedTurnIsNotInProgress() throws {
        #expect(try fold("turn-interrupt").turnInProgress == false)
    }

    // turn-queued: one `result` carries queued_turn_count 1 by edit, because a real run here cannot queue a turn.
    @Test func aQueuedTurnStaysInProgressAtTheResultAndAfterTheNextTurnsEvents() throws {
        var fold = SessionStatusFold()
        let lines = try ConversationFixtures.lines("turn-queued")
        let resultIndex = try #require(lines.firstIndex { $0.contains("\"type\":\"result\"") })
        fold.feed(Array(lines[...resultIndex]))
        #expect(fold.turnInProgress == true)
        fold.feed(Array(lines[(resultIndex + 1)...]))
        #expect(fold.turnInProgress == true)
    }

    @Test func controlTrafficAfterATurnDoesNotStartOne() throws {
        #expect(try fold("turn-control-only").turnInProgress == false)
    }

    @Test func aLocalCommandReplyWhileIdleDoesNotStartATurn() throws {
        // set-model: result, then the "Set model to" reply, its control_response, and a second pair.
        #expect(try fold("set-model").turnInProgress == false)
    }

    @Test func aMalformedLineChangesNothing() throws {
        var fold = try self.fold("turn-mid")
        fold.feed("{not json")
        fold.feed("{\"type\":")
        #expect(fold.turnInProgress == true)
        var done = try self.fold("turn-done")
        done.feed("garbage")
        #expect(done.turnInProgress == false)
    }

    @Test func contextPercentUsesTheLastIterationNotTheTopLevelUsage() throws {
        // (2 + 442 + 49870 + 58591) / 1,000,000; the top-level usage would give 22.
        #expect(try fold("status-turn").contextPercent == 11)
    }

    @Test func contextPercentIsNilBeforeTheFirstResult() throws {
        #expect(try fold("turn-mid").contextPercent == nil)
    }

    @Test func theModelIsTheSetModelResponseAndStaysAfterATwoKeyResult() throws {
        #expect(try fold("status-model-switch").model == "claude-sonnet-5-5")
    }

    @Test func theEffortComesFromTheResultText() throws {
        #expect(try fold("status-effort").effort == "high")
    }

    @Test func aBareEffortUserLineWithoutAConfirmingResultGivesNoEffort() {
        var f = SessionStatusFold()
        f.feed(#"{"type":"user","message":{"role":"user","content":"/effort high"}}"#)
        #expect(f.effort == nil)
        f.feed(#"{"type":"user","message":{"role":"user","content":"/effort bogus"}}"#)
        f.feed(#"{"type":"result","result":"Invalid effort level"}"#)
        #expect(f.effort == nil)
    }

    @Test func bothLimitWindowsComeFromTheRateLimitEvent() throws {
        let f = try fold("status-limits")
        #expect(f.fiveHour?.utilization != nil)
        #expect(f.sevenDay?.resetsAt != nil)
    }

    @Test func aWindowMissingFromTheNewestEventKeepsTheEarlierValue() {
        var f = SessionStatusFold()
        f.feed(#"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.2,"resetsAt":10},"seven_day":{"utilization":0.3,"resetsAt":20}}}}"#)
        f.feed(#"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":11}}}}"#)
        #expect(f.fiveHour?.utilization == 0.5)
        #expect(f.sevenDay?.utilization == 0.3)
    }
}
