import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct ExecuteScreenTextTests {
    private func plan(_ file: String, _ k: Int, _ status: String?, body: String = "", rows: [ExecuteReport.Row] = [])
        -> ExecuteScreenData.PlanData {
        let report = status.map { ExecuteReport(firstLine: $0, body: body, rows: rows) }
        return .init(file: file, k: k, name: "N\(k)", status: status, report: report)
    }

    private func data(_ waves: [[ExecuteScreenData.PlanData]], source: ExecuteScreenData.Source = .worktree) -> ExecuteScreenData {
        ExecuteScreenData(source: source, result: .loaded(waves: waves))
    }

    @Test func fiveStatesShowInWaveOrder() {
        let waves = [
            [plan("PLAN-1.md", 1, "PLAN COMPLETE", rows: [.init(task: "1 a", commit: "abc1234", note: "ok")])],
            [plan("PLAN-2.md", 2, "PLAN PARTIAL"), plan("PLAN-3.md", 3, "PLAN CHECKPOINT: structural", body: "Plan: x\n|---|---|\nNeed: a call\nOpen items: none")],
            [plan("PLAN-4.md", 4, nil)],
        ]
        let text = ExecuteScreenText.make(phase: "1", data: data(waves), overlay: nil, live: true)
        let titles = text.waves.flatMap { $0.plans.map(\.title) }
        #expect(titles == ["1. N1 [done]", "2. N2 [running]", "3. N3 [checkpoint]", "4. N4 [waiting]"])
        #expect(text.waves[0].plans[0].rows == [.init(task: "1 a", commit: "abc1234", note: "ok")])
        #expect(text.waves[1].plans[1].headline == "PLAN CHECKPOINT: structural" && text.waves[1].plans[1].body == "Need: a call")
        let partial = ExecuteScreenText.make(phase: "1", data: data([[plan("PLAN-1.md", 1, "PLAN PARTIAL")]]), overlay: nil, live: false)
        #expect(partial.waves[0].plans[0].title == "1. N1 [partial]  FAILED")
    }

    @Test func aDeadWorkerPartialShowsTheFirstLineByteForByte() {
        let line = "PLAN PARTIAL"
        let body = "Plan: x\nTasks: 2 of 5\nDeviations: none"
        let text = ExecuteScreenText.make(phase: "1", data: data([[plan("PLAN-1.md", 1, line, body: body)]]), overlay: nil, live: false)
        let block = text.waves[0].plans[0]
        // User-directed (plan 2): the body is not dumped; only a Need: line shows.
        #expect(block.failure && block.headline == line && block.body == nil)
        let needy = ExecuteScreenText.make(phase: "1", data: data([[plan("PLAN-1.md", 1, line, body: body + "\nNeed: a decision")]]),
                                           overlay: nil, live: false)
        #expect(needy.waves[0].plans[0].body == "Need: a decision")
    }

    @Test func aBlockedCheckpointWithALiveWorkerIsAFailure() {
        let text = ExecuteScreenText.make(phase: "1", data: data([[plan("PLAN-1.md", 1, "PLAN CHECKPOINT: blocked", body: "why")]]),
                                          overlay: nil, live: true)
        #expect(text.waves[0].plans[0].failure && text.waves[0].plans[0].headline == "PLAN CHECKPOINT: blocked")
    }

    /// User-directed (plan 3): the coordinator asks at suite-red too, so an open question beats the no-answer line.
    @Test func aSuiteRedCheckpointWithAnOpenQuestionWaitsForTheAnswer() {
        let p = plan("PLAN-1.md", 1, "PLAN CHECKPOINT: suite-red", body: "Need: a call")
        func line(open: Bool, live: Bool = true) -> String? {
            ExecuteScreenText.make(phase: "1", data: data([[p]]), overlay: nil, live: live, questionOpen: open).waves[0].plans[0].answerLine
        }
        #expect(line(open: true) == "waiting for your answer")
        #expect(line(open: false) == "no answer needed: the next executor starts by itself")
        #expect(line(open: true, live: false) == nil)
    }

    /// User-directed (plan 3): the old question and typed answer no longer stay above the plan list after a card is answered.
    @Test func theExecuteScreenKeepsNoAnsweredQuestionLine() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OrchestratorGUI/ExecuteScreenView.swift").path
        #expect(!(try String(contentsOfFile: path, encoding: .utf8)).contains("answered(for"))
    }

    @Test func aLiveCheckpointShowsTheAnswerLineAndADeadOneShowsNone() {
        func block(_ type: String, live: Bool) -> ExecuteScreenText.PlanBlock {
            let p = plan("PLAN-1.md", 1, "PLAN CHECKPOINT: \(type)", body: "Need: a call")
            return ExecuteScreenText.make(phase: "1", data: data([[p]]), overlay: nil, live: live).waves[0].plans[0]
        }
        let structural = block("structural", live: true)
        #expect(structural.answerLine == "waiting for your answer" && structural.headline == "PLAN CHECKPOINT: structural")
        #expect(block("suite-red", live: true).answerLine == "no answer needed: the next executor starts by itself")
        let dead = block("decision", live: false)
        #expect(dead.answerLine == nil && dead.failure && dead.headline == "PLAN CHECKPOINT: decision")
    }

    @Test func gitMarksAMissingHashAndNamesAnUncheckedRun() {
        let rows: [ExecuteReport.Row] = [.init(task: "1 a", commit: "abc1234", note: "ok"), .init(task: "2 b", commit: "deadbee", note: "ok"),
                                         .init(task: "3 c", commit: "-", note: "n")]
        func block(_ commits: ExecuteCommits.Outcome?) -> ExecuteScreenText.PlanBlock {
            var p = plan("PLAN-1.md", 1, "PLAN COMPLETE", rows: rows)
            p.commits = commits
            return ExecuteScreenText.make(phase: "1", data: data([[p]]), overlay: nil, live: true).waves[0].plans[0]
        }
        let checked = block(.checked([.resolved, .missing, .notHash]))
        #expect(checked.rows[0].note == "ok" && checked.rows[2].note == "n" && checked.gitLine == nil)
        #expect(checked.rows[1].commit == "deadbee" && checked.rows[1].note.hasSuffix("not found in git"))
        let unchecked = block(.unchecked("git timed out"))
        #expect(unchecked.gitLine == "git not checked: git timed out" && unchecked.rows.map(\.note) == ["ok", "ok", "n"])
        #expect(block(nil).gitLine == nil)
    }

    @Test func copyLinesAndMessages() {
        let project = ExecuteScreenText.make(phase: "1", data: data([[plan("PLAN-1.md", 1, nil)]], source: .project), overlay: nil, live: false)
        #expect(project.copyLine == "Showing the project copy" && project.header == "Execute: phase 1 - no worker")
        let worktree = ExecuteScreenText.make(phase: "1", data: data([]), overlay: nil, live: false)
        #expect(worktree.copyLine == "Showing the worktree copy (not merged yet)" && worktree.message == "no plans found")
        let unplanned = ExecuteScreenText.make(phase: "1", data: ExecuteScreenData(source: .project, result: .notPlanned), overlay: nil, live: false)
        #expect(unplanned.message == "not planned")
        let bad = ExecuteScreenText.make(phase: "x", data: ExecuteScreenData(source: .none, result: .unreadable("bad")), overlay: nil, live: false)
        #expect(bad.message == "bad" && bad.copyLine == nil)
        #expect(ExecuteScreenText.make(phase: "1", data: ExecuteScreenData(), overlay: nil, live: false).message == "nothing found")
    }
}
