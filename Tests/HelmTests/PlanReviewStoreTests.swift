import Foundation
import Testing
@testable import Helm

private final class Opens: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ p: String) { lock.lock(); list.append(p); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

@Suite struct PlanReviewLoaderTests {
    private let wavesJSON = #"{"ok":true,"phase":4,"plans":[],"overlaps":[],"waves":[["PLAN-1.md","PLAN-3.md"],["PLAN-2.md"]]}"#

    private func temp() -> String {
        let p = NSTemporaryDirectory() + "prs-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }

    private func write(_ path: String, _ text: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func populate(_ root: String, marker: String) {
        for n in ["PLAN-1.md", "PLAN-2.md", "PLAN-3.md", "secret.txt", "PLAN-x.md", "PLAN.md.bak", "PLANNING.md"] {
            write("\(root)/.planning/phases/4/\(n)", "# \(marker) \(n)\n")
        }
        write("\(root)/.planning/phases/4/records/REVIEW-plan.md", "# \(marker) review\n")
    }

    private func setDate(_ path: String, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private func review(_ project: String, files: [String]) -> (exists: Bool, path: String, opens: Opens) {
        for n in files { write("\(project)/.planning/phases/4/records/\(n)", "x") }
        let opens = Opens()
        let data = loader(opens).load(project: project, phase: "4", worktree: nil)
        return (data.reviewExists, data.reviewPath, opens)
    }

    @Test func reviewPlanInRecordsIsFoundAndNeverRead() {
        let r = review(temp(), files: ["REVIEW-plan.md"])
        #expect(r.exists)
        #expect(r.path == ".planning/phases/4/records/REVIEW-plan.md")
        #expect(!r.opens.all.contains { $0.contains("REVIEW") })
    }

    @Test func aSuffixedPlanReviewAloneIsFound() {
        let r = review(temp(), files: ["REVIEW-plan-plan-2.md"])
        #expect(r.exists && r.path.hasSuffix("records/REVIEW-plan-plan-2.md"))
    }

    @Test func theNewerPlanReviewWinsAndSwappingDatesSwapsIt() {
        let project = temp()
        _ = review(project, files: ["REVIEW-plan.md", "REVIEW-plan-plan-2.md"])
        let a = "\(project)/.planning/phases/4/records/REVIEW-plan.md"
        let b = "\(project)/.planning/phases/4/records/REVIEW-plan-plan-2.md"
        setDate(a, Date(timeIntervalSince1970: 2_000_000)); setDate(b, Date(timeIntervalSince1970: 1_000_000))
        #expect(loader(Opens()).load(project: project, phase: "4", worktree: nil).reviewPath.hasSuffix("records/REVIEW-plan.md"))
        setDate(a, Date(timeIntervalSince1970: 1_000_000)); setDate(b, Date(timeIntervalSince1970: 2_000_000))
        #expect(loader(Opens()).load(project: project, phase: "4", worktree: nil).reviewPath.hasSuffix("records/REVIEW-plan-plan-2.md"))
    }

    @Test func otherReviewKindsDoNotCount() {
        let r = review(temp(), files: ["REVIEW-risk_surface-plan-1.md", "REVIEW-diff-a-b.md", "REVIEW-phase_diff-a-b.md"])
        #expect(!r.exists && r.path.isEmpty)
    }

    @Test func aReviewAtThePhaseTopDoesNotCount() {
        let project = temp()
        write(project + "/.planning/phases/4/REVIEW-plan.md", "x")
        let data = loader(Opens()).load(project: project, phase: "4", worktree: nil)
        #expect(!data.reviewExists && data.reviewPath.isEmpty)
    }

    private func loader(_ opens: Opens, json: String? = nil, ran: Opens? = nil) -> PlanReviewLoader {
        let out = json ?? wavesJSON
        return PlanReviewLoader(
            read: { opens.add($0); return try? String(contentsOfFile: $0, encoding: .utf8) },
            runner: { root, phase in
                ran?.add("\(root)|\(phase)")
                return ProcessResult(status: 0, stdout: out, stderr: "")
            })
    }

    @Test func wavesComeBackGroupedAndWorktreeIsReadNotProject() {
        let project = temp(), wt = project + "/.claude/worktrees/w"
        populate(project, marker: "project"); populate(wt, marker: "worktree")
        let opens = Opens()
        let data = loader(opens).load(project: project, phase: "4", worktree: wt)
        #expect(data.root == .worktree)
        #expect(data.waves.map { $0.map(\.name) } == [["PLAN-1.md", "PLAN-3.md"], ["PLAN-2.md"]])
        #expect(data.waves[0][0].parsed.raw.contains("worktree"))
        #expect(data.reviewExists)
        #expect(!opens.all.contains { $0.hasPrefix(project + "/.planning/phases/4/PLAN") })
    }

    @Test func removedWorktreeFallsBackToProject() {
        let project = temp()
        populate(project, marker: "project")
        let data = loader(Opens()).load(project: project, phase: "4", worktree: project + "/.claude/worktrees/gone")
        #expect(data.root == .project)
        #expect(data.waves[0][0].parsed.raw.contains("project"))
    }

    @Test func aWorktreePathOutsideTheWorktreesFolderIsIgnored() {
        let project = temp(), other = temp()
        populate(project, marker: "project"); populate(other, marker: "other")
        let data = loader(Opens()).load(project: project, phase: "4", worktree: other)
        #expect(data.root == .project)
        #expect(data.waves[0][0].parsed.raw.contains("project"))
    }

    @Test func onlyNamedFilesAndContextAreOpened() {
        let project = temp()
        populate(project, marker: "project")
        write(project + "/.planning/phases/4/CONTEXT.md", "## Acceptance criteria\n\n- [ ] AC1: x\n")
        let opens = Opens()
        let data = loader(opens).load(project: project, phase: "4", worktree: nil)
        let dir = project + "/.planning/phases/4/"
        #expect(Set(opens.all) == Set(["PLAN-1.md", "PLAN-3.md", "PLAN-2.md"].map { dir + $0 } + [dir + "CONTEXT.md"]))
        #expect(data.criteria == ["- [ ] AC1: x"])
    }

    @Test func aReviewSymlinkOutsideTheRootIsNotRead() {
        let project = temp(), outside = temp()
        populate(project, marker: "project")
        write(outside + "/r.md", "x")
        let review = project + "/.planning/phases/4/records/REVIEW-plan.md"
        try? FileManager.default.removeItem(atPath: review)
        try? FileManager.default.createSymbolicLink(atPath: review, withDestinationPath: outside + "/r.md")
        #expect(!loader(Opens()).load(project: project, phase: "4", worktree: nil).reviewExists)
    }

    @Test func notOkGivesNoPlanFiles() {
        let project = temp()
        let data = loader(Opens(), json: #"{"ok":false,"reason":"no phase folder"}"#).load(project: project, phase: "4", worktree: nil)
        #expect(!data.hasPlanFiles)
    }

    @Test func badPhaseTextBuildsNoPathAndRunsNoProcess() {
        let ran = Opens()
        let l = loader(Opens(), ran: ran)
        #expect(l.load(project: "/p", phase: "../x", worktree: nil) == PlanReviewData())
        #expect(l.load(project: "/p", phase: "4x", worktree: nil) == PlanReviewData())
        #expect(l.planWaves(root: "/p", phase: "../x").isEmpty)
        #expect(ran.all.isEmpty)
    }

    @Test func namesFromTheRunnerAreFiltered() {
        let l = loader(Opens(), json: #"{"ok":true,"waves":[["PLAN-1.md","../evil.md","PLAN.md.bak"]]}"#)
        #expect(l.planWaves(root: "/p", phase: "4") == [["PLAN-1.md"]])
    }

    @Test func loadingTwiceGivesEqualDataAndChangesNoFile() throws {
        let project = temp()
        populate(project, marker: "project")
        let dir = project + "/.planning/phases/4/"
        func mtimes() -> [String: Date] {
            Dictionary(uniqueKeysWithValues: ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map {
                ($0, (try? FileManager.default.attributesOfItem(atPath: dir + $0)[.modificationDate] as? Date) ?? .distantPast)
            })
        }
        let before = mtimes()
        let a = loader(Opens()).load(project: project, phase: "4", worktree: nil)
        let b = loader(Opens()).load(project: project, phase: "4", worktree: nil)
        #expect(a == b)
        #expect(mtimes() == before)
    }

    @Test func gitStatusStaysCleanInBothCheckouts() throws {
        let project = temp()
        func git(_ cwd: String, _ args: [String]) -> String {
            ProcessRunner.run("/usr/bin/git", args, environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                              workingFolder: cwd, timeout: 20).stdout
        }
        _ = git(project, ["init", "-q"])
        populate(project, marker: "project")
        _ = git(project, ["-c", "user.email=a@b", "-c", "user.name=t", "add", "-A"])
        _ = git(project, ["-c", "user.email=a@b", "-c", "user.name=t", "commit", "-qm", "init"])
        let wt = project + "/.claude/worktrees/w"
        _ = git(project, ["worktree", "add", "-q", wt])
        _ = loader(Opens()).load(project: project, phase: "4", worktree: wt)
        #expect(git(project, ["status", "--porcelain", ".planning"]).isEmpty)
        #expect(git(wt, ["status", "--porcelain", ".planning"]).isEmpty)
    }
}

@MainActor @Suite struct PlanReviewStorePublishTests {
    @Test func aSecondLoadWithIdenticalContentPublishesNothing() async {
        let project = NSTemporaryDirectory() + "prs-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: project + "/.planning", withIntermediateDirectories: true)
        let store = PlanReviewStore(loader: PlanReviewLoader(
            read: { _ in nil }, runner: { _, _ in ProcessResult(status: 0, stdout: #"{"ok":false}"#, stderr: "") }))
        var changes = 0
        let sub = store.objectWillChange.sink { changes += 1 }
        store.point(project: project, phase: "4", worktree: nil)
        // Wait for the first publish, not a fixed time: a loaded machine can take seconds.
        for _ in 0..<200 where changes == 0 { try? await Task.sleep(for: .milliseconds(50)) }
        let first = changes
        store.reload()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(changes == first)
        _ = sub
    }
}
