import Foundation
import Testing
@testable import Helm

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

struct UATGateCheckTests {
    private static func loaded(_ result: String, _ counts: UATStatus.Counts) -> UATStatus.Outcome {
        .loaded(UATStatus(status: "testing", counts: counts, result: result, firstPending: nil, ci: nil))
    }
    private static let complete = loaded("complete", .init(pass: 6))

    private func project(uat: Bool = true) throws -> (root: String, worktree: String) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory() + "uat-gate-" + UUID().uuidString.prefix(8).lowercased())
        let wt = base.appendingPathComponent(".claude/worktrees/cad-verify-p3")
        try FileManager.default.createDirectory(at: wt.appendingPathComponent(".planning/phases/3"), withIntermediateDirectories: true)
        if uat { try "x".write(to: wt.appendingPathComponent(".planning/phases/3/UAT.md"), atomically: true, encoding: .utf8) }
        return (base.resolvingSymlinksInPath().path, wt.resolvingSymlinksInPath().path)
    }

    private func row(_ label: String, _ worktree: String?) -> WorkerRow {
        WorkerRow(agentId: label, status: "running", taskTitle: nil, lastEvent: "done", worktreePath: worktree)
    }

    private func check(status: UATStatus.Outcome = complete, tracked: Int32 = 0, dirty: String = "", timeout: Bool = false,
                       calls: Calls = Calls()) -> UATGateCheck {
        UATGateCheck(
            status: { _, _ in calls.hit(); return status },
            git: { args in
                calls.hit()
                if timeout { return ProcessResult(status: -1, stdout: "", stderr: "", timedOut: true) }
                return args.contains("ls-files") ? ProcessResult(status: tracked, stdout: "", stderr: "")
                    : ProcessResult(status: 0, stdout: dirty, stderr: "")
            })
    }

    @Test func otherLabelsRunNothing() throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p.root) }
        let calls = Calls()
        for label in ["cad-execute-p3", "cad-plan-p3", "cad-context-p3", "fix-bug"] {
            #expect(check(calls: calls).run(project: p.root, row: row(label, p.worktree)) == .notGated)
        }
        #expect(calls.count == 0)
    }

    @Test func completeAndCommittedIsAllowed() throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p.root) }
        #expect(check().run(project: p.root, row: row("cad-verify-p3", p.worktree)) == .allowed)
    }

    @Test func blocksOnPartialUntrackedDirtyAndGitTimeout() throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p.root) }
        let r = row("cad-verify-p3", p.worktree)
        func blocked(_ v: UATGate.Verdict) -> Bool { if case .blocked = v { return true } else { return false } }
        #expect(blocked(check(status: Self.loaded("partial", .init(pending: 1))).run(project: p.root, row: r)))
        #expect(check(tracked: 1).run(project: p.root, row: r) == .blocked("UAT.md is not committed in the worktree"))
        #expect(check(dirty: " M .planning/phases/3/UAT.md\n").run(project: p.root, row: r)
                == .blocked("UAT.md is not committed in the worktree"))
        #expect(check(tracked: 128).run(project: p.root, row: r) == .blocked("git ls-files exited 128"))
        #expect(check(timeout: true).run(project: p.root, row: r) == .blocked("git timed out"))
    }

    @Test func worktreeOutsideOrGoneIsBlockedAndRunsNothing() throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p.root) }
        let calls = Calls()
        let outside = try project()
        defer { try? FileManager.default.removeItem(atPath: outside.root) }
        #expect(check(calls: calls).run(project: p.root, row: row("cad-verify-p3", outside.worktree)) == .blocked("worker worktree is gone"))
        #expect(check(calls: calls).run(project: p.root, row: row("cad-verify-p3", p.worktree + "-nope")) == .blocked("worker worktree is gone"))
        #expect(check(calls: calls).run(project: p.root, row: row("cad-verify-p3", nil)) == .blocked("worker worktree is gone"))
        #expect(calls.count == 0)
    }

    @Test func missingOrEscapingUatIsBlockedWithoutStatus() throws {
        let calls = Calls()
        let none = try project(uat: false)
        defer { try? FileManager.default.removeItem(atPath: none.root) }
        guard case .blocked = check(calls: calls).run(project: none.root, row: row("cad-verify-p3", none.worktree)) else {
            Issue.record("expected blocked"); return
        }
        let link = try project(uat: false)
        defer { try? FileManager.default.removeItem(atPath: link.root) }
        let target = link.root + "/outside.md"
        try "x".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link.worktree + "/.planning/phases/3/UAT.md", withDestinationPath: target)
        guard case .blocked = check(calls: calls).run(project: link.root, row: row("cad-verify-p3", link.worktree)) else {
            Issue.record("expected blocked"); return
        }
        #expect(calls.count == 0)
    }

    // MARK: integration (real node, git, Cadence)

    private func git(_ dir: String, _ args: [String]) {
        let r = FolderCheck.runGit(["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t"] + args)
        #expect(r.status == 0, "git \(args): \(r.stderr)")
    }

    private func uatText(_ lines: [String]) -> String {
        let items = lines.enumerated().map { "### \($0.offset + 1). item\nexpected: e\n\($0.element)\n" }.joined(separator: "\n")
        return "---\nstatus: testing\nphase: 3\nfields_version: 1\nstarted: 2026-11-10\nupdated: 2026-11-10\n---\n\n## Items\n\n" + items
    }

    @Test func realRepoVerdicts() throws {
        guard FolderCheck.gitPath() != nil, case .success = CadenceLocator.locate() else {
            print("skipped: git or the Cadence install is missing"); return
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "uat-gate-real-" + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let main = root.resolvingSymlinksInPath().path
        defer { try? FileManager.default.removeItem(atPath: main) }
        git(main, ["init", "-q", "-b", "main"])
        git(main, ["commit", "-q", "--allow-empty", "-m", "init"])
        let wt = main + "/.claude/worktrees/cad-verify-p3"
        git(main, ["worktree", "add", "-q", "-b", "wt", wt])
        let wtReal = URL(fileURLWithPath: wt).resolvingSymlinksInPath().path
        let dir = wtReal + "/.planning/phases/3"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/UAT.md"
        try "# Roadmap\n\n## Phases\n\n- [ ] **Phase 3: Third** - c\n"
            .write(toFile: wtReal + "/.planning/ROADMAP.md", atomically: true, encoding: .utf8)
        git(wtReal, ["add", ".planning/ROADMAP.md"])
        git(wtReal, ["commit", "-q", "-m", "roadmap"])
        let r = row("cad-verify-p3", wtReal)
        let gate = UATGateCheck()

        try uatText(Array(repeating: "status: pass", count: 6)).write(toFile: file, atomically: true, encoding: .utf8)
        #expect(gate.run(project: main, row: r) == .blocked("UAT.md is not committed in the worktree"), "untracked")
        git(wtReal, ["add", ".planning/phases/3/UAT.md"])
        git(wtReal, ["commit", "-q", "-m", "uat"])
        #expect(gate.run(project: main, row: r) == .allowed)

        try (uatText(Array(repeating: "status: pass", count: 6)) + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        #expect(gate.run(project: main, row: r) == .blocked("UAT.md is not committed in the worktree"), "edited")
        git(wtReal, ["commit", "-q", "-am", "uat2"])

        try uatText(Array(repeating: "status: pass", count: 5) + ["status: skipped\nreason: no device"])
            .write(toFile: file, atomically: true, encoding: .utf8)
        git(wtReal, ["commit", "-q", "-am", "skip"])
        #expect(gate.run(project: main, row: r) == .confirmSkipped(1))

        try uatText(Array(repeating: "status: pass", count: 5) + ["status: blocked\nreason: no device"])
            .write(toFile: file, atomically: true, encoding: .utf8)
        git(wtReal, ["commit", "-q", "-am", "blocked"])
        guard case .blocked = gate.run(project: main, row: r) else { Issue.record("blocked UAT passed"); return }

        let found = FileManager.default.enumerator(atPath: main)?.allObjects as? [String] ?? []
        #expect(!found.contains { $0.hasSuffix("trace.jsonl") })
        let status = FolderCheck.runGit(["-C", wtReal, "status", "--porcelain", ".planning", ":(exclude).planning/records"])
        #expect(status.stdout.isEmpty, "porcelain: \(status.stdout)")
    }
}
