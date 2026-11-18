import Foundation
import Testing
@testable import Helm

private func row(_ task: String, _ commit: String) -> ExecuteReport.Row {
    ExecuteReport.Row(task: task, commit: commit, note: "from git")
}

private func block(report: ExecuteReport?, gitRows: [ExecuteReport.Row]) -> ExecuteScreenText.PlanBlock? {
    let plan = ExecuteScreenData.PlanData(file: "PLAN-1.md", k: 1, name: "A", status: report == nil ? nil : "PLAN PARTIAL",
                                          report: report, commits: nil, gitRows: gitRows)
    let data = ExecuteScreenData(source: .worktree, result: .loaded(waves: [[plan]]))
    return ExecuteScreenText.make(phase: "2", data: data, overlay: nil, live: true).waves.first?.plans.first
}

@Suite struct ExecuteLiveRowsTests {
    @Test func onlyThePlansScopeIsKeptOldestFirstWithTheSubjectAfterTheScope() {
        let log = "c3\tfix(2-2): other plan\nb2\tfeat(2-1): beta\na1\tfeat(2-1): alpha: first\n9f\tfeat(2-10): ten\n"
            + "8e\tfeat(12-1): twelve\n7d\tMerge branch x\n6c\t(2-1): no type\n"
        #expect(ExecuteCommits.liveRows(log: log, phase: "2", k: 1) == [row("alpha: first", "a1"), row("beta", "b2")])
        #expect(ExecuteCommits.liveRows(log: "", phase: "2", k: 1).isEmpty)
    }

    @Test func gitRowsShowWithoutAReportAndTheReportRowsReplaceThemOnceItListsThemAll() {
        let git = [row("alpha", "a1"), row("beta", "b2")]
        let live = block(report: nil, gitRows: git)
        #expect(live?.rows.map(\.commit) == ["a1", "b2"] && live?.rows.map(\.note) == ["from git", "from git"])
        let one = ExecuteReport.parse("PLAN PARTIAL\n\n| Task | Commit | Note |\n|---|---|---|\n| alpha | a1 | ok |\n")
        #expect(block(report: one, gitRows: git)?.rows.map(\.commit) == ["a1", "b2"])
        let two = ExecuteReport.parse("PLAN PARTIAL\n\n| Task | Commit | Note |\n|---|---|---|\n| alpha | a1 | ok |\n| beta | b2 | ok |\n")
        #expect(block(report: two, gitRows: git)?.rows.map(\.note) == ["ok", "ok"])
    }

    @Test func noWorktreeMeansNoGitRowsAndNoGitRun() throws {
        let project = NSTemporaryDirectory() + UUID().uuidString
        let worktree = "\(project)/.claude/worktrees/w"
        try FileManager.default.createDirectory(atPath: "\(worktree)/.planning/phases/2", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(project)/.planning/phases/2", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: project) }
        let asked = LockedList()
        let loader = ExecuteScreenLoader(
            run: { _, _ in
                .loaded(plans: [ExecuteCadence.Plan(file: "PLAN-1.md", k: 1, exists: false,
                                                    status: nil, name: "A")], waves: [["PLAN-1.md"]])
            },
            readReport: { _, _, _ in nil },
            liveCommits: { worktree, _ in asked.add(worktree); return "a1\tfeat(2-1): alpha\n" })
        func gitRows(_ data: ExecuteScreenData) -> [ExecuteReport.Row]? {
            guard case .loaded(let waves) = data.result else { return nil }
            return waves.first?.first?.gitRows
        }
        #expect(gitRows(loader.load(project: project, phase: "2", worktree: nil)) == [])
        #expect(asked.all.isEmpty)
        #expect(gitRows(loader.load(project: project, phase: "2", worktree: worktree)) == [row("alpha", "a1")])
        #expect(asked.all == [URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path])
    }
}

private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}
