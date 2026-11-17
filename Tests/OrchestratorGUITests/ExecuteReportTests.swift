import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct ExecuteReportTests {
    private let archived = """
    PLAN COMPLETE
    Plan: .planning/phases/4/PLAN-1.md
    Tasks: 8 of 8
    | Task | Commit | Note |
    |---|---|---|
    | 1 Screen case, stub, Open plan button | 8524002 | NavigationStateTests, WorkflowStoreTests green |
    | 2 Parse a plan file | e8e8ffc | PlanReviewParserTests 6/6 |
    | 3 Acceptance criteria parser | 45f6dbc | ContextCriteriaTests 4/4 |
    | 4 Plan data source | 8a45c7f | loader/store tests green |
    | 5 Screen state rule | ccc0fe8 | PlanReviewStateTests 9/9 |
    | 6 Board shows Plan ready | 9824ce0 | commit carried WorkflowOverlay.swift (user-approved since) |
    | 7 Plan questions join stage table | fb84803 | ContextCardStateTests + WorkflowStoreTests 64/64 |
    | 8 Draw the plan review screen | 9350cfb | PlanReviewTextTests 9/9 |
    | repair round | bfde8a5 | wait for first publish instead of fixed 200 ms |
    Suite run 1: RED, 1 issue.
    Deviations: none

    --- Continuation dispatch (suite regression) ---
    | not | a | row after the table |
    """

    @Test func parsesTheArchivedReport() {
        let report = ExecuteReport.parse(archived)
        #expect(report.firstLine == "PLAN COMPLETE")
        #expect(report.rows.count == 9)
        #expect(report.rows.first?.commit == "8524002" && report.rows.last?.commit == "bfde8a5")
        #expect(report.rows[0].task == "1 Screen case, stub, Open plan button")
        #expect(report.rows[0].note == "NavigationStateTests, WorkflowStoreTests green")
        #expect(report.body == archived.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
    }

    @Test func malformedRowsAreSkippedAndNoPipeNotesKeepTheText() {
        let report = ExecuteReport.parse("PLAN PARTIAL\n| Task | Commit | Note |\n|---|---|---|\n| only one |\n| 1 a | abc1234 | plain note |\n")
        #expect(report.rows == [.init(task: "1 a", commit: "abc1234", note: "plain note")])
    }

    @Test func readsOnlyTheExactNamedFileAndRefusesSymlinksOutOfTheRoot() throws {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        let reports = "\(dir)/root/.planning/phases/1/records/reports"
        try FileManager.default.createDirectory(atPath: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let root = "\(dir)/root"
        #expect(ExecuteReport.read(root: root, phase: "1", k: 1) == nil)
        try "PLAN PARTIAL\n".write(toFile: "\(reports)/plan-1.md", atomically: true, encoding: .utf8)
        try "PLAN COMPLETE\n".write(toFile: "\(reports)/plan-2.1.md", atomically: true, encoding: .utf8)
        #expect(ExecuteReport.read(root: root, phase: "1", k: 1)?.firstLine == "PLAN PARTIAL")
        #expect(ExecuteReport.read(root: root, phase: "1", k: 2) == nil)
        try "PLAN COMPLETE\n".write(toFile: "\(dir)/outside.md", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: "\(reports)/plan-3.md", withDestinationPath: "\(dir)/outside.md")
        #expect(ExecuteReport.read(root: root, phase: "1", k: 3) == nil)
        #expect(ExecuteReport.read(root: root, phase: "../1", k: 1) == nil)
    }
}
