import Foundation
import Testing
@testable import OrchestratorGUI

/// AC7: the plan store load, the Approve path and the Notes path change nothing under `.planning/`.
@MainActor @Suite struct PlanReviewReadOnlyTests {
    private func git(_ args: [String], in dir: String) -> String {
        let base = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        return ProcessRunner.run("/usr/bin/git", base + args, environment: ["HOME": NSHomeDirectory()],
                                 workingFolder: dir, timeout: 20).stdout
    }

    private func snapshot(_ root: String) -> [String: Date] {
        var out: [String: Date] = [:]
        let dir = root + "/.planning"
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: dir)) ?? []
        for name in names {
            let path = dir + "/" + name
            out[name] = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return out
    }

    @Test func loadApproveAndNotesWriteNothingUnderPlanning() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory() + "prro-" + UUID().uuidString).resolvingSymlinksInPath().path
        let project = base + "/project", worktree = base + "/wt"
        try fm.createDirectory(atPath: project + "/.planning/phases/4/records", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        for n in ["PLAN-1.md", "records/REVIEW-plan.md"] {
            try "---\nphase: 4\nplan: 1\n---\n# Plan\n".write(toFile: "\(project)/.planning/phases/4/\(n)", atomically: true, encoding: .utf8)
        }
        _ = git(["init", "-q"], in: project)
        _ = git(["add", "-A"], in: project)
        _ = git(["commit", "-q", "-m", "init"], in: project)
        _ = git(["worktree", "add", "-q", "-b", "b", worktree], in: project)
        try #require(fm.fileExists(atPath: worktree + "/.planning/phases/4/PLAN-1.md"))

        let inbox = base + "/inbox.jsonl"
        fm.createFile(atPath: inbox, contents: Data())
        let wavesJSON = #"{"ok":true,"phase":4,"plans":[],"overlaps":[],"waves":[["PLAN-1.md"]]}"#
        let loader = PlanReviewLoader(runner: { _, _ in ProcessResult(status: 0, stdout: wavesJSON, stderr: "", startError: nil) })
        let beforeProject = snapshot(project), beforeWorktree = snapshot(worktree)

        let data = loader.load(project: project, phase: "4", worktree: worktree)
        #expect(data.hasPlanFiles)

        var starts = 0
        let buttons = PlanReviewActions.make(state: .readyForReview(reviewInFlight: false), gate: "advisory", notesInFlight: false)
        PlanReviewActions.press(try #require(buttons.approve), confirmed: false, label: "cad-plan-p4") { _ in starts += 1 }
        #expect(starts == 1)
        let linesAfterApprove = try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n").count
        #expect(linesAfterApprove == 0)

        let row = WorkerRow(agentId: "cad-plan-p4", status: "running", taskTitle: nil, lastEvent: "done", inboxPath: inbox)
        let sender = PlanNoteSender()
        sender.notes = "shorten wave 2"
        await sender.send(phase: "4", rows: [row])
        let linesAfterNotes = try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n").count
        #expect(linesAfterNotes == 1)

        #expect(snapshot(project) == beforeProject && snapshot(worktree) == beforeWorktree)
        #expect(git(["status", "--porcelain", ".planning"], in: project).isEmpty)
        #expect(git(["status", "--porcelain", ".planning"], in: worktree).isEmpty)
    }
}
