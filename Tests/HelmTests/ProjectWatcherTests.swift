import Foundation
import Testing
@testable import Helm

/// Counts callbacks from the watcher's queue.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func bump() { lock.lock(); _value += 1; lock.unlock() }
}

@Suite(.serialized) struct ProjectWatcherTests {
    @Test func streamOnAProjectWithoutClaudeCallsBackWhenTheDatabaseAppears() async throws {
        let fx = try FixtureProject.make(withDatabase: false)
        defer { fx.remove() }
        let hits = Counter()
        let watcher = ProjectWatcher(project: fx.path) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(300))
        try fx.write()
        for _ in 0..<300 where hits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value >= 1)
    }

    @Test func otherNamesAndTheWorktreesFolderCauseNoCallback() async throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let hits = Counter()
        let watcher = ProjectWatcher(project: fx.path) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        let before = hits.value
        let claude = fx.path + "/.claude"
        try FileManager.default.createDirectory(atPath: claude + "/worktrees/alpha", withIntermediateDirectories: true)
        try "x".write(toFile: claude + "/worktrees/alpha/session-state.db", atomically: false, encoding: .utf8)
        try "x".write(toFile: claude + "/notes.txt", atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(hits.value == before)
    }

    private func tempFolder() throws -> String {
        let path = NSTemporaryDirectory() + "gui-test-watch-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func folderModeCallsBackWhenAnyFileIsCreated() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let hits = Counter()
        let watcher = ProjectWatcher(folder: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(300))
        try "x".write(toFile: folder + "/%3.json", atomically: false, encoding: .utf8)
        for _ in 0..<300 where hits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value >= 1)
    }

    @Test func folderModeCallsBackWhenAFileIsReplacedByRename() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try "old".write(toFile: folder + "/%3.json", atomically: false, encoding: .utf8)
        let hits = Counter()
        let watcher = ProjectWatcher(folder: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        try "new".write(toFile: folder + "/%3.json.tmp", atomically: false, encoding: .utf8)
        // The tmp file's own events must have arrived before the count is taken, so only the rename is measured.
        try await Task.sleep(for: .milliseconds(800))
        let before = hits.value
        #expect(rename(folder + "/%3.json.tmp", folder + "/%3.json") == 0)
        for _ in 0..<300 where hits.value == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value > before)
    }

    /// Runs `action` after the stream has started and returns whether a callback came within 3 seconds.
    private func holdsCallback(
        _ fx: FixtureProject, prepare: () throws -> Void = {}, _ action: () throws -> Void
    ) async throws -> Bool {
        try prepare()
        let hits = Counter()
        let watcher = ProjectWatcher(holdsOf: fx.path) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        let before = hits.value
        try action()
        for _ in 0..<300 where hits.value == before { try await Task.sleep(for: .milliseconds(10)) }
        return hits.value > before
    }

    private func holdsFolder(_ fx: FixtureProject) -> String { fx.path + "/.claude/gate-holds" }

    private func makeHoldsFolder(_ fx: FixtureProject) throws {
        try FileManager.default.createDirectory(atPath: holdsFolder(fx), withIntermediateDirectories: true)
    }

    @Test(arguments: ["a.pending", "a.decision"]) func holdsModeCallsBackWhenAHoldFileIsCreatedAndRemoved(name: String) async throws {
        let fx = try FixtureProject.make(withDatabase: false)
        defer { fx.remove() }
        let path = holdsFolder(fx) + "/" + name
        #expect(try await holdsCallback(fx, prepare: { try makeHoldsFolder(fx) }) { try "x".write(toFile: path, atomically: false, encoding: .utf8) })
        #expect(try await holdsCallback(fx) { try FileManager.default.removeItem(atPath: path) })
    }

    @Test func holdsModeIgnoresTmpNotifiedAndOtherNames() async throws {
        let fx = try FixtureProject.make(withDatabase: false)
        defer { fx.remove() }
        let called = try await holdsCallback(fx, prepare: { try makeHoldsFolder(fx) }) {
            for name in [".tmp.a", ".tmp.a.pending", "a.notified", "notes.txt", "a.pending.tmp"] {
                try "x".write(toFile: holdsFolder(fx) + "/" + name, atomically: false, encoding: .utf8)
            }
            try "x".write(toFile: fx.path + "/.claude/session-state.db", atomically: false, encoding: .utf8)
        }
        #expect(!called)
    }

    @Test func holdsModeIgnoresTheWorktreesFolder() async throws {
        let fx = try FixtureProject.make(withDatabase: false)
        defer { fx.remove() }
        let nested = fx.path + "/.claude/worktrees/alpha/.claude/gate-holds"
        let called = try await holdsCallback(fx, prepare: { try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true) }) {
            try "x".write(toFile: nested + "/a.pending", atomically: false, encoding: .utf8)
        }
        #expect(!called)
    }

    @Test func holdsModeCallsBackWhenTheFolderIsCreatedAfterTheStart() async throws {
        let fx = try FixtureProject.make(withDatabase: false)
        defer { fx.remove() }
        #expect(try await holdsCallback(fx) { try makeHoldsFolder(fx) })
    }

    @Test func databaseModeStillIgnoresHoldFiles() async throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let hits = Counter()
        let watcher = ProjectWatcher(project: fx.path) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        let before = hits.value
        try makeHoldsFolder(fx)
        try "x".write(toFile: holdsFolder(fx) + "/a.pending", atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(hits.value == before)
    }

    // MARK: task-list mode

    private func taskListPath(_ fx: FixtureProject) -> String { fx.path + "/.claude/" + TaskListFile.name }

    /// Runs `action` after the stream has started and returns whether a task-list callback came within 3 seconds.
    private func taskListCallback(_ fx: FixtureProject, _ action: () throws -> Void) async throws -> Bool {
        try FileManager.default.createDirectory(atPath: fx.path + "/.claude", withIntermediateDirectories: true)
        let hits = Counter()
        let watcher = ProjectWatcher(taskListOf: fx.path) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        try action()
        for _ in 0..<300 where hits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        return hits.value > 0
    }

    @Test func taskListModeCallsBackWhenATempFileIsRenamedOntoTheFile() async throws {
        let fx = try FixtureProject.make(withDatabase: false)
        defer { fx.remove() }
        let called = try await taskListCallback(fx) {
            let temp = fx.path + "/.claude/.notion-tasks.AbC123"
            try "{}".write(toFile: temp, atomically: false, encoding: .utf8)
            try FileManager.default.moveItem(atPath: temp, toPath: taskListPath(fx))
        }
        #expect(called)
    }

    @Test func taskListModeIgnoresOtherNamesAndTempFiles() async throws {
        let fx = try FixtureProject.make(withDatabase: false)
        defer { fx.remove() }
        let called = try await taskListCallback(fx) {
            for name in ["session-state.db", ".notion-tasks.AbC123", "notion-tasks.json.bak", "other.json"] {
                try "x".write(toFile: fx.path + "/.claude/" + name, atomically: false, encoding: .utf8)
            }
        }
        #expect(!called)
    }

    @Test func aTaskListWriteFiresNeitherTheDatabaseNorTheHoldsMode() async throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let db = Counter(), holds = Counter()
        let dbWatcher = ProjectWatcher(project: fx.path) { db.bump() }
        let holdsWatcher = ProjectWatcher(holdsOf: fx.path) { holds.bump() }
        defer { _ = (dbWatcher, holdsWatcher) }
        try await Task.sleep(for: .milliseconds(800))
        // Events from creating the fixture can still arrive; count only what the task-list write adds.
        let (dbBefore, holdsBefore) = (db.value, holds.value)
        try "{}".write(toFile: taskListPath(fx), atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(db.value == dbBefore)
        #expect(holds.value == holdsBefore)
    }

    @Test func planningModeFiresOnStateWriteButNotOnTraceOrReads() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder + "/.planning", withIntermediateDirectories: true)
        // Create the files first: the create step can go through a temp name, which is not an append.
        for name in ["trace.jsonl", "reads.jsonl"] {
            try "".write(toFile: folder + "/.planning/" + name, atomically: false, encoding: .utf8)
        }
        let hits = Counter()
        let watcher = ProjectWatcher(planningOf: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        let quietBefore = hits.value
        for name in ["trace.jsonl", "reads.jsonl"] {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: folder + "/.planning/" + name))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{}\n".utf8))
            try handle.close()
        }
        try await Task.sleep(for: .milliseconds(2000))
        #expect(hits.value == quietBefore)
        try "x".write(toFile: folder + "/.planning/STATE.md", atomically: false, encoding: .utf8)
        for _ in 0..<500 where hits.value == quietBefore { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value > quietBefore)
    }

    @Test func planningModeSkipsRecordsWritesExceptStateJson() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let records = folder + "/.planning/records"
        try FileManager.default.createDirectory(atPath: records, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(2000))
        let hits = Counter()
        let watcher = ProjectWatcher(planningOf: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        let quietBefore = hits.value
        for name in ["trace.jsonl", "trace.1.jsonl", "trace.1.jsonl.claim", "reads.jsonl.rotate.x1", ".state.json.tmp123"] {
            try "x".write(toFile: records + "/" + name, atomically: false, encoding: .utf8)
        }
        try await Task.sleep(for: .milliseconds(2000))
        #expect(hits.value == quietBefore)
        try "{}".write(toFile: records + "/state.json", atomically: false, encoding: .utf8)
        for _ in 0..<500 where hits.value == quietBefore { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value > quietBefore)
    }

    @Test func uatModeFiresOnAWriteAndOnARenameOntoUATmd() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let hits = Counter()
        let watcher = ProjectWatcher(uatIn: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        try "x".write(toFile: folder + "/UAT.md", atomically: false, encoding: .utf8)
        for _ in 0..<500 where hits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value >= 1)
        try "y".write(toFile: folder + "/.UAT.md.tmp", atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(800))
        let before = hits.value
        #expect(rename(folder + "/.UAT.md.tmp", folder + "/UAT.md") == 0)
        for _ in 0..<500 where hits.value == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value > before)
    }

    @Test func uatModeIgnoresOtherNamesAndStopsWhenReleased() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let hits = Counter()
        var watcher: ProjectWatcher? = ProjectWatcher(uatIn: folder) { hits.bump() }
        try await Task.sleep(for: .milliseconds(800))
        try "x".write(toFile: folder + "/PLAN-1.md", atomically: false, encoding: .utf8)
        try "".write(toFile: folder + "/trace.jsonl", atomically: false, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: folder + "/trace.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        try await Task.sleep(for: .milliseconds(2000))
        #expect(hits.value == 0)
        watcher = nil
        try await Task.sleep(for: .milliseconds(500))
        try "x".write(toFile: folder + "/UAT.md", atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(hits.value == 0)
    }

    @Test func reportsModeSeesAReportWrittenIntoAnExistingFolder() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder + "/reports", withIntermediateDirectories: true)
        let hits = Counter()
        let watcher = ProjectWatcher(reportsIn: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        try "x".write(toFile: folder + "/reports/plan-1.md", atomically: false, encoding: .utf8)
        for _ in 0..<500 where hits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value >= 1)
    }

    @Test func reportsModeSeesTheReportsFolderCreatedLater() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let hits = Counter()
        let watcher = ProjectWatcher(reportsIn: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        try FileManager.default.createDirectory(atPath: folder + "/reports", withIntermediateDirectories: true)
        for _ in 0..<500 where hits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let before = hits.value
        #expect(before >= 1)
        try "x".write(toFile: folder + "/reports/plan-1.md", atomically: false, encoding: .utf8)
        for _ in 0..<500 where hits.value == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value > before)
    }

    @Test func reportsModeSeesRecordsReportsAtDepthTwo() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder + "/records/reports", withIntermediateDirectories: true)
        let hits = Counter()
        let watcher = ProjectWatcher(reportsIn: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        try "x".write(toFile: folder + "/records/reports/plan-1.md", atomically: false, encoding: .utf8)
        for _ in 0..<500 where hits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value >= 1)
    }

    @Test func reportsModeSeesRecordsReportsCreatedLater() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let hits = Counter()
        let watcher = ProjectWatcher(reportsIn: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        try FileManager.default.createDirectory(atPath: folder + "/records/reports", withIntermediateDirectories: true)
        for _ in 0..<500 where hits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let before = hits.value
        #expect(before >= 1)
        try "x".write(toFile: folder + "/records/reports/plan-1.md", atomically: false, encoding: .utf8)
        for _ in 0..<500 where hits.value == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value > before)
    }

    @Test func reportsModeIgnoresPlanUatAndDotNames() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder + "/reports", withIntermediateDirectories: true)
        // FSEvents can replay the folder's creation just before the stream starts; let it pass first.
        try await Task.sleep(for: .milliseconds(2000))
        let hits = Counter()
        let watcher = ProjectWatcher(reportsIn: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        try "x".write(toFile: folder + "/PLAN-1.md", atomically: false, encoding: .utf8)
        try "x".write(toFile: folder + "/UAT.md", atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(2000))
        #expect(hits.value == 0)
        try "x".write(toFile: folder + "/reports/.plan-1.md.tmp", atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(2000))
        #expect(hits.value == 0)
    }

    @Test func planningModeSeesAFolderCreatedAfterTheWatcherStarted() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let hits = Counter()
        let watcher = ProjectWatcher(planningOf: folder) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        try FileManager.default.createDirectory(atPath: folder + "/.planning", withIntermediateDirectories: true)
        try "x".write(toFile: folder + "/.planning/STATE.md", atomically: false, encoding: .utf8)
        for _ in 0..<500 where hits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value >= 1)
    }

    @Test func fileModeFiresOnAWriteAndARenameButNotOnSiblingsOrSameNameDeeper() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let file = folder + "/a.swift"
        try "x".write(toFile: file, atomically: false, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: folder + "/sub", withIntermediateDirectories: true)
        // FSEvents can still report changes made just before the stream starts, so let the setup writes age first.
        try await Task.sleep(for: .milliseconds(1500))
        let hits = Counter()
        let watcher = ProjectWatcher(file: file) { hits.bump() }
        defer { _ = watcher }
        try await Task.sleep(for: .milliseconds(800))
        try "y".write(toFile: folder + "/b.swift", atomically: false, encoding: .utf8)
        try "y".write(toFile: folder + "/sub/a.swift", atomically: false, encoding: .utf8)
        try "y".write(toFile: folder + "/.a.swift.tmp", atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(2000))
        #expect(hits.value == 0)
        try "z".write(toFile: file, atomically: false, encoding: .utf8)
        for _ in 0..<500 where hits.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value >= 1)
        try await Task.sleep(for: .milliseconds(800))
        let before = hits.value
        #expect(rename(folder + "/.a.swift.tmp", file) == 0)
        for _ in 0..<500 where hits.value == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hits.value > before)
    }
}
