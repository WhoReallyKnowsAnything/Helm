import Combine
import Foundation
import Testing
@testable import Helm

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [String] = []
    private var reads: [String] = []
    func run(_ root: String) { lock.withLock { runs.append(root) } }
    func read(_ path: String) { lock.withLock { reads.append(path) } }
    var allRuns: [String] { lock.withLock { runs } }
    var allReads: [String] { lock.withLock { reads } }
}

private func plan(_ file: String, _ k: Int, exists: Bool, status: String?) -> ExecuteCadence.Plan {
    ExecuteCadence.Plan(file: file, k: k, exists: exists, status: status,
                        name: "P\(k)")
}

private func loader(_ recorder: Recorder) -> ExecuteScreenLoader {
    ExecuteScreenLoader(
        run: { root, _ in
            recorder.run(root)
            return .loaded(plans: [plan("PLAN-1.md", 1, exists: true, status: "PLAN PARTIAL"),
                                   plan("PLAN-2.md", 2, exists: false, status: nil)],
                           waves: [["PLAN-1.md"], ["PLAN-2.md"]])
        },
        readReport: { root, phase, k in
            recorder.read("\(root)/.planning/phases/\(phase)/records/reports/plan-\(k).md")
            return ExecuteReport.parse("PLAN PARTIAL\n")
        })
}

@Suite struct ExecuteScreenLoaderTests {
    private func fixture() throws -> (project: String, worktree: String) {
        let project = NSTemporaryDirectory() + UUID().uuidString
        let worktree = "\(project)/.claude/worktrees/w"
        try FileManager.default.createDirectory(atPath: "\(worktree)/.planning/phases/1", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(project)/.planning/phases/1", withIntermediateDirectories: true)
        return (project, worktree)
    }

    @Test func theWorktreeCopyWinsAndTheProjectCopyIsReadOnceItIsGone() throws {
        let (project, worktree) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project) }
        let recorder = Recorder()
        let real = URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path
        let first = loader(recorder).load(project: project, phase: "1", worktree: worktree)
        #expect(first.source == .worktree)
        try FileManager.default.removeItem(atPath: worktree)
        let second = loader(recorder).load(project: project, phase: "1", worktree: worktree)
        #expect(second.source == .project)
        #expect(recorder.allRuns == [real, project])
    }

    @Test func aWorktreeOutsideTheProjectWorktreesFolderIsIgnored() throws {
        let (project, _) = try fixture()
        let other = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: "\(other)/.planning/phases/1", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: project); try? FileManager.default.removeItem(atPath: other) }
        let data = loader(Recorder()).load(project: project, phase: "1", worktree: other)
        #expect(data.source == .project)
    }

    @Test func onlyListedReportFilesAreOpenedAndWavesKeepTheirOrder() throws {
        let (project, _) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project) }
        let recorder = Recorder()
        let data = loader(recorder).load(project: project, phase: "1", worktree: nil)
        #expect(recorder.allReads == ["\(project)/.planning/phases/1/records/reports/plan-1.md"])
        guard case .loaded(let waves) = data.result else { Issue.record("not loaded"); return }
        #expect(waves.map { $0.map(\.file) } == [["PLAN-1.md"], ["PLAN-2.md"]])
        #expect(waves[0][0].report?.firstLine == "PLAN PARTIAL" && waves[1][0].report == nil)
    }

    @Test func anInvalidPhaseRunsNothing() {
        let recorder = Recorder()
        let data = loader(recorder).load(project: "/p", phase: "../1", worktree: nil)
        #expect(data.source == .none)
        #expect(recorder.allRuns.isEmpty)
    }
}

@MainActor @Suite struct ExecuteScreenStoreTests {
    @Test func anIdenticalReloadPublishesNothing() async throws {
        let project = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: "\(project)/.planning/phases/1", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: project) }
        let store = ExecuteScreenStore(loader: loader(Recorder()))
        var published = 0
        let sink = store.$data.dropFirst().sink { _ in published += 1 }
        store.point(project: project, phase: "1", worktree: nil)
        for _ in 0..<300 where store.data.source == .none { try await Task.sleep(for: .milliseconds(10)) }
        #expect(published == 1)
        store.reload()
        try await Task.sleep(for: .milliseconds(200))
        #expect(published == 1)
        sink.cancel()
    }

    private func gitProject() throws -> (project: String, hash: String) {
        let home = NSTemporaryDirectory() + "exec-store-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try "[user]\n\tname = T\n\temail = t@example.com\n".write(toFile: home + "/.gitconfig", atomically: true, encoding: .utf8)
        let env = ["PATH": OrchestratorPaths.searchPath, "HOME": home, "LANG": "en_US.UTF-8"]
        let project = NSTemporaryDirectory() + "exec-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        _ = FolderCheck.runGit(["-C", project, "init"], environment: env)
        _ = FolderCheck.runGit(["-C", project, "commit", "--allow-empty", "-m", "c"], environment: env)
        let hash = FolderCheck.runGit(["-C", project, "rev-parse", "--short", "HEAD"], environment: env)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (project, hash)
    }

    private func put(_ root: String, rows: [String]) throws {
        let dir = "\(root)/.planning/phases/1/records/reports"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let table = rows.map { "| \($0) | ok |" }.joined(separator: "\n")
        try "PLAN PARTIAL\n| Task | Commit | Note |\n|---|---|---|\n\(table)\n"
            .write(toFile: dir + "/plan-1.md", atomically: true, encoding: .utf8)
    }

    private func realLoader() -> ExecuteScreenLoader {
        ExecuteScreenLoader(run: { _, _ in
            .loaded(plans: [plan("PLAN-1.md", 1, exists: true, status: "PLAN PARTIAL")], waves: [["PLAN-1.md"]])
        })
    }

    private func checks(_ data: ExecuteScreenData) -> [ExecuteCommits.Check]? {
        guard case .loaded(let waves) = data.result, case .checked(let list)? = waves.first?.first?.commits else { return nil }
        return list
    }

    @Test func rewritingTheWorktreeReportRepublishesWithinFiveSecondsWithCheckedHashes() async throws {
        let (project, hash) = try gitProject()
        defer { try? FileManager.default.removeItem(atPath: project) }
        let worktree = "\(project)/.claude/worktrees/w"
        try put(worktree, rows: ["1 a | \(hash)"])
        let store = ExecuteScreenStore(loader: realLoader())
        store.point(project: project, phase: "1", worktree: worktree)
        for _ in 0..<500 where store.data.source == .none { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.data.source == .worktree && checks(store.data) == [.resolved])
        try await Task.sleep(for: .milliseconds(800))
        try put(worktree, rows: ["1 a | \(hash)", "2 b | deadbee"])
        for _ in 0..<500 where checks(store.data)?.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(checks(store.data) == [.resolved, .missing])
    }

    @Test func afterTheWorktreeIsGoneTheProjectCopyStillResolves() async throws {
        let (project, hash) = try gitProject()
        defer { try? FileManager.default.removeItem(atPath: project) }
        try put(project, rows: ["1 a | \(hash)"])
        let store = ExecuteScreenStore(loader: realLoader())
        store.point(project: project, phase: "1", worktree: "\(project)/.claude/worktrees/gone")
        for _ in 0..<500 where store.data.source == .none { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.data.source == .project && checks(store.data) == [.resolved])
    }

    private func gitRows(_ data: ExecuteScreenData) -> [ExecuteReport.Row] {
        guard case .loaded(let waves) = data.result else { return [] }
        return waves.first?.first?.gitRows ?? []
    }

    @Test func aNewTaskCommitShowsItsRowAndHashWithinFiveSecondsWithNoTimer() async throws {
        let (project, _) = try gitProject()
        defer { try? FileManager.default.removeItem(atPath: project) }
        let home = NSTemporaryDirectory() + "exec-store-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let env = ["PATH": OrchestratorPaths.searchPath, "HOME": home, "LANG": "en_US.UTF-8",
                   "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
                   "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com"]
        let worktree = "\(project)/.claude/worktrees/w"
        #expect(FolderCheck.runGit(["-C", project, "worktree", "add", "-b", "wt", worktree], environment: env).status == 0)
        try FileManager.default.createDirectory(atPath: "\(worktree)/.planning/phases/1", withIntermediateDirectories: true)
        let store = ExecuteScreenStore(loader: realLoader())
        store.point(project: project, phase: "1", worktree: worktree)
        for _ in 0..<500 where store.data.source != .worktree { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.data.source == .worktree && gitRows(store.data).isEmpty)
        try await Task.sleep(for: .milliseconds(800))
        #expect(FolderCheck.runGit(["-C", worktree, "commit", "--allow-empty", "-m", "feat(1-1): add the thing"], environment: env).status == 0)
        let hash = FolderCheck.runGit(["-C", worktree, "rev-parse", "--short", "HEAD"], environment: env)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<500 where gitRows(store.data).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gitRows(store.data).map(\.commit) == [hash])
        #expect(gitRows(store.data).map(\.task) == ["add the thing"])
    }

    @Test func theViewSourceHasNoTimer() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Helm/ExecuteScreenView.swift")
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("Timer"))
    }

    @Test func theStoreSourceHasNoTimer() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Helm/ExecuteScreenStore.swift")
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("Timer"))
    }

    @Test func aStaleGenerationResultIsDropped() {
        let store = ExecuteScreenStore(loader: loader(Recorder()))
        let stale = ExecuteScreenData(source: .project, result: .notPlanned)
        store.finish(stale, generation: store.currentGeneration - 1)
        #expect(store.data.source == .none)
        store.finish(stale, generation: store.currentGeneration)
        #expect(store.data.source == .project)
    }
}
