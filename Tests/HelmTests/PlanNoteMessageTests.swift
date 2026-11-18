import Foundation
import Testing
@testable import Helm

@Suite struct PlanNoteMessageTests {
    private func build(_ phase: String, _ notes: String = "fix it") throws -> String {
        try PlanNoteMessage.make(phase: phase, notes: notes).get()
    }

    @Test func instructionNamesPhaseAndSteps() throws {
        let m4 = try build("4")
        #expect(m4.hasPrefix("The user asks for changes to the plan for phase 4"))
        #expect(m4.contains("/cadence:cad-plan-review 4"))
        #expect(try build("1.1").contains("/cadence:cad-plan-review 1.1"))
        #expect(m4.contains("--mark-done cad-plan-p4"))
        #expect(try build("1.1").contains("--mark-done cad-plan-p1.1"))
        for part in ["--mark-done", ".claude/orchestrator-root", "git rev-parse --git-common-dir"] {
            #expect(m4.contains(part))
        }
    }

    @Test func markDoneComesAfterReviewAndCommit() throws {
        let m = try build("4")
        let review = try #require(m.range(of: "/cadence:cad-plan-review"))
        let commit = try #require(m.range(of: "commit on your branch"))
        let done = try #require(m.range(of: "--mark-done"))
        #expect(review.lowerBound < commit.lowerBound && commit.lowerBound < done.lowerBound)
        #expect(m.contains("$ORCH_ROOT/orchestration/lib/dispatch-task.sh") && !m.contains("/Users/"))
    }

    @Test func notesAreAppendedByteForByte() throws {
        let inputs = ["a\nb", "tab\there", "$(touch /tmp/x)", "`ls`", " lead and trail ", "héllo 日本",
                      PlanNoteMessage.marker, "run /cadence:cad-plan-review 9"]
        for notes in inputs {
            #expect(try build("4", notes).hasSuffix(notes))
        }
    }

    @Test func badPhaseRefused() {
        for phase in ["4x", "../x", "", "4.", "4\n"] {
            #expect(PlanNoteMessage.make(phase: phase, notes: "n") == .failure(.badPhase))
        }
    }

    @Test func blankNotesRefused() {
        for notes in ["", "   ", "\n"] {
            #expect(PlanNoteMessage.make(phase: "4", notes: notes) == .failure(.emptyNotes))
        }
    }
}
