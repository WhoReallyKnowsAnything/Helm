import Foundation
import Testing
@testable import OrchestratorGUI

struct QuestionInputTests {
    private func fixtureInput() throws -> Data {
        var fold = ControlRequests()
        let lines = try ConversationFixtures.lines("ask-user-question")
        fold.feed(lines.filter { $0.contains("control_request") })
        return try #require(fold.pending.first).input
    }

    @Test func theRecordedRequestDecodesToItsQuestionsAndOptions() throws {
        let questions = QuestionInput.decode(try fixtureInput())
        #expect(questions.map(\.text) == ["Which color?", "Which fruits?"])
        #expect(questions.map(\.header) == ["Color", "Fruits"])
        #expect(questions.map { $0.options.map(\.label) } == [["Red", "Blue"], ["Apple", "Pear", "Plum"]])
        #expect(questions.map(\.multiSelect) == [false, true])
    }

    @Test(arguments: [
        #"{}"#, #"{"questions":[]}"#, #"not json"#,
        #"{"questions":[{"options":[{"label":"A"}]}]}"#,
        #"{"questions":[{"question":"Q","options":[]}]}"#,
        #"{"questions":[{"question":"Q"}]}"#,
        #"{"questions":[{"question":"Q","options":[{"description":"d"}]}]}"#,
        #"{"questions":[{"question":"Q","options":[{"label":"A"}]},{"question":"Q","options":[{"label":"B"}]}]}"#,
    ])
    func unanswerableInputsDecodeToNothing(_ json: String) {
        #expect(QuestionInput.decode(Data(json.utf8)).isEmpty)
    }

    @Test func displayTextEscapesATabButRawTextKeepsIt() throws {
        let json = #"{"questions":[{"question":"a\tb","options":[{"label":"x","description":"d"}]}]}"#
        let question = try #require(QuestionInput.decode(Data(json.utf8)).first)
        #expect(question.display == #"a\tb"#)
        #expect(question.text == "a\tb")
    }
}
