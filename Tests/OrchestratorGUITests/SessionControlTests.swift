import Foundation
import Testing
@testable import OrchestratorGUI

struct SessionControlTests {
    @Test func theModelFollowsInitThenEachSetModelResponse() throws {
        var control = SessionControl()
        var seen: [String] = []
        for line in try ConversationFixtures.lines("set-model") {
            control.feed(line)
            if let model = control.model, seen.last != model { seen.append(model) }
        }
        #expect(seen == ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
    }

    @Test func theInterruptMovesFromSendingToAnsweredToEnded() throws {
        var control = SessionControl()
        control.noteInterrupt(id: "req-int-1")
        #expect(control.interrupt == .sending)
        var phases: [SessionControl.Phase] = []
        for line in try ConversationFixtures.lines("interrupt-tool") {
            control.feed(line)
            if let phase = control.interrupt, phases.last != phase { phases.append(phase) }
        }
        #expect(phases == [.sending, .answered, .ended])
    }

    @Test func anotherRequestIdDoesNotAnswerTheInterrupt() {
        var control = SessionControl()
        control.noteInterrupt(id: "mine")
        control.feed(#"{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}"#)
        control.feed(#"{"type":"result","subtype":"error_during_execution"}"#)
        #expect(control.interrupt == .sending)
    }

    @Test func aLogWithoutInitGivesNoModelAndGarbageIsIgnored() {
        var control = SessionControl()
        control.feed(["{not json \"init\"", #"{"type":"user","message":{}}"#, #"{"type":"system","subtype":"init"}"#])
        #expect(control.model == nil && control.interrupt == nil)
    }
}
