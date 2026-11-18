import Foundation
import Testing
@testable import Helm

private final class Opens: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

@Suite struct ContextScreenStoreTests {
    private let doc = "## Decisions\n\n- D-01 (area): text\n"

    private func temp() throws -> String {
        let d = NSTemporaryDirectory() + "ctxstore-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return URL(fileURLWithPath: d).resolvingSymlinksInPath().path
    }

    private func put(_ root: String, _ phase: String, _ text: String? = nil) throws {
        let dir = "\(root)/.planning/phases/\(phase)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try (text ?? doc).write(toFile: dir + "/CONTEXT.md", atomically: true, encoding: .utf8)
    }

    private func worktree(_ project: String) throws -> String {
        let wt = project + "/.claude/worktrees/wt"
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        return wt
    }

    private func load(_ project: String, _ phase: String = "3", wt: String? = nil, opens: Opens = Opens()) -> ContextScreenData {
        ContextScreenLoader(read: { opens.add($0); return try? String(contentsOfFile: $0, encoding: .utf8) })
            .load(project: project, phase: phase, worktree: wt)
    }

    @Test func nothingAnywhereGivesNone() throws {
        let p = try temp()
        #expect(load(p).source == .none)
    }

    @Test func worktreeCopyShownWhileProjectHasNone() throws {
        let p = try temp(), wt = try worktree(p)
        try put(wt, "3", "## Decisions\n- D-07 (a): in worktree\n")
        let d = load(p, wt: wt)
        #expect(d.source == .worktree)
        #expect(d.current.map(\.number) == [7])
    }

    @Test func removedWorktreeFallsBackToProject() throws {
        let p = try temp(), wt = try worktree(p)
        try put(wt, "3", "## Decisions\n- D-07 (a): in worktree\n")
        try put(p, "3")
        try FileManager.default.removeItem(atPath: wt)
        let d = load(p, wt: wt)
        #expect(d.source == .project)
        #expect(d.current.map(\.number) == [1])
    }

    @Test func worktreeOutsideClaudeWorktreesIsIgnored() throws {
        let p = try temp(), other = try temp()
        try put(other, "3")
        #expect(load(p, wt: other).source == .none)
    }

    @Test func onlyTheNamedFilesAreOpened() throws {
        let p = try temp(), wt = try worktree(p)
        for n in ["1", "2", "3"] { try put(p, n) }
        try put(wt, "4")
        try "x".write(toFile: p + "/.planning/secret.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: wt + "/secret.txt", atomically: true, encoding: .utf8)
        let opens = Opens()
        _ = load(p, "4", wt: wt, opens: opens)
        #expect(Set(opens.all) == Set(["1", "2", "3"].map { "\(p)/.planning/phases/\($0)/CONTEXT.md" } + ["\(wt)/.planning/phases/4/CONTEXT.md"]))
        #expect(!opens.all.contains { $0.hasSuffix("secret.txt") })
    }

    @Test func worktreeWithoutContextReadsNothingThere() throws {
        let p = try temp(), wt = try worktree(p)
        try put(p, "3")
        var opens = Opens()
        #expect(load(p, wt: wt, opens: opens).source == .project)
        #expect(!opens.all.contains { $0.hasPrefix(wt) })
        let q = try temp(), wt2 = try worktree(q)
        opens = Opens()
        #expect(load(q, wt: wt2, opens: opens).source == .none)
        #expect(!opens.all.contains { $0.hasPrefix(wt2) })
    }

    @Test func symlinkOutOfWorktreeIsNotRead() throws {
        let p = try temp(), wt = try worktree(p), outside = try temp()
        try "## Decisions\n- D-09 (a): outside\n".write(toFile: outside + "/c.md", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: wt + "/.planning/phases/3", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: wt + "/.planning/phases/3/CONTEXT.md", withDestinationPath: outside + "/c.md")
        let opens = Opens()
        #expect(load(p, wt: wt, opens: opens).source == .none)
        #expect(opens.all.isEmpty)
    }

    @Test func badPhaseTextBuildsNoPath() throws {
        let p = try temp()
        try put(p, "3")
        for bad in ["../x", "3x"] {
            let opens = Opens()
            #expect(load(p, bad, opens: opens).source == .none)
            #expect(opens.all.isEmpty)
        }
    }

    /// AC8: loading changes nothing under `.planning/` in either checkout.
    @Test func loadingLeavesGitAndModificationTimesUntouched() throws {
        let p = try temp()
        func git(_ args: [String], in dir: String) throws -> String {
            let proc = Process(), out = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["git", "-c", "user.name=t", "-c", "user.email=t@t"] + args
            proc.currentDirectoryURL = URL(fileURLWithPath: dir)
            proc.standardOutput = out
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        _ = try git(["init", "-q"], in: p)
        try put(p, "2")
        _ = try git(["add", "."], in: p)
        _ = try git(["commit", "-q", "-m", "x"], in: p)
        let wt = p + "/.claude/worktrees/wt"
        _ = try git(["worktree", "add", "-q", wt, "-b", "w"], in: p)
        try put(wt, "3")
        func stamps() -> [String: Date] {
            var m: [String: Date] = [:]
            for root in [p, wt] {
                for f in FileManager.default.enumerator(atPath: root + "/.planning")?.allObjects as? [String] ?? [] {
                    m["\(root)/\(f)"] = (try? FileManager.default.attributesOfItem(atPath: "\(root)/.planning/\(f)"))?[.modificationDate] as? Date
                }
            }
            return m
        }
        let before = stamps()
        #expect(load(p, wt: wt).source == .worktree)
        #expect(try git(["status", "--porcelain", ".planning"], in: p).isEmpty)
        #expect(stamps() == before)
    }

    // MARK: display text (Task 7)

    private func d(_ phase: String, _ n: Int) -> ContextDecision { ContextDecision(phase: phase, number: n, area: "area", text: "text \(n)") }

    private func text(_ data: ContextScreenData, state: ContextCardState.State = .answerable,
                      answered: [AnsweredQuestions] = []) -> ContextScreenText {
        let overlay = WorkflowOverlay(stage: .context, state: .running, label: "cad-context-p3")
        return ContextScreenText.make(phase: "3", data: data, overlay: overlay, state: state, answered: answered)
    }

    @Test func threeEarlierPhasesKeepTheirLabels() {
        let t = text(ContextScreenData(earlier: [d("2", 1), d("1", 2), d("0", 3)], current: [], source: .project))
        #expect(t.sections.map(\.heading) == ["Phase 2", "Phase 1", "Phase 0"])
        #expect(t.sections[1].lines == [.init(title: "Phase 1 D-02 (area)", text: "text 2")])
    }

    @Test func thisPhaseIsMarkedOnlyForTheWorktree() {
        let wt = text(ContextScreenData(earlier: [], current: [d("3", 1)], source: .worktree))
        let pr = text(ContextScreenData(earlier: [], current: [d("3", 1)], source: .project))
        #expect(wt.sections.first?.note == "not merged yet")
        #expect(pr.sections.first?.note == nil)
    }

    @Test func liveAndAnsweredCardsShowAndADeadCardHasNoSend() {
        let q = QuestionInput.Question(text: "Pick?", header: nil, options: [.init(label: "A", description: "")], multiSelect: false)
        let done = AnsweredQuestions(key: "k", nodeKey: "cad-context-p3", questions: [q], picks: ["Pick?": ["A"]])
        let live = text(ContextScreenData(), answered: [done])
        #expect(live.answered == ["Pick?: A"] && live.endedLine == nil)
        #expect(ContextCardState.state(label: "cad-context-p3", overlay: .running, live: true) == .answerable)

        let dead = text(ContextScreenData(), state: .workerEnded)
        #expect(dead.endedLine == "worker ended")
        let entry = RequestStore.Entry(key: "k", nodeKey: "cad-context-p3",
                                       request: PermissionRequest(requestId: "r", toolName: "AskUserQuestion", toolUseId: "t", input: Data("{}".utf8),
                                                         displayName: nil, text: "q", reason: nil),
                                       live: false)
        let card = ContextCardState.card(for: entry, state: .workerEnded)
        #expect(card?.showsButtons == false && ContextCardState.offersClear(.workerEnded))
    }
}
