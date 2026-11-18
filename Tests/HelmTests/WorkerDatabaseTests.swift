import Foundation
import SQLite3
import Testing
@testable import Helm

/// Helpers shared by the worker tests: file bytes, `.dump`, sidecar removal.
enum WorkerFiles {
    static func bytes(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

    static func dump(_ db: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, ".dump"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Safe only after a checkpoint, which the fixture script runs. Leaves an idle database.
    static func removeSidecars(_ db: String) {
        try? FileManager.default.removeItem(atPath: db + "-wal")
        try? FileManager.default.removeItem(atPath: db + "-shm")
    }
}

@Suite(.serialized) struct WorkerDatabaseTests {
    private let order = ["alpha", "bravo", "charlie", "delta"]

    private func loaded(_ read: WorkerRead) throws -> WorkerState {
        guard case .loaded(let state) = read else { throw NSError(domain: "WorkerDatabaseTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(read)"]) }
        return state
    }

    @Test func fixtureGivesRowsInOrderWithRawStatusAndDependencies() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let state = try loaded(reader.read())
        #expect(state.rows.map(\.agentId) == order)
        #expect(state.rows.map(\.status) == ["running", "blocked", "running", "merged"])
        #expect(state.rows.map(\.lastEvent) == [nil, nil, "done", nil])
        #expect(state.rows.first?.taskTitle == "Build the parser")
        #expect(state.dependencies == [WorkerDependency(dependent: "alpha", upstream: "delta"),
                                       WorkerDependency(dependent: "bravo", upstream: "alpha")])
        #expect(state.missing.isEmpty)
    }

    @Test func oldSchemaGivesSameRowsWithNilOptionalColumnsAndAMissingList() throws {
        let fx = try FixtureProject.make(schema: "old-schema")
        defer { fx.remove() }
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let state = try loaded(reader.read())
        #expect(state.rows.map(\.agentId) == order)
        #expect(state.rows.map(\.status) == ["running", "blocked", "running", "merged"])
        #expect(state.rows.allSatisfy { $0.taskTitle == nil && $0.lastEvent == nil })
        #expect(state.missing == ["task_title", "last_event"])
    }

    @Test func rowsCarryTheNodeInfoColumnsAndANullStaysNil() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        try fx.sql("UPDATE sessions SET model = 'Sonnet 5.5', effort = 'xhigh', claude_session_id = 'sid-1' WHERE agent_id = 'alpha'")
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let state = try loaded(reader.read())
        let alpha = try #require(state.rows.first)
        #expect(alpha.worktreePath == "/fx/alpha")
        #expect(alpha.claudeSessionId == "sid-1")
        #expect(alpha.model == "Sonnet 5.5")
        #expect(alpha.effort == "xhigh")
        let bravo = state.rows[1]
        #expect(bravo.claudeSessionId == nil && bravo.model == nil && bravo.effort == nil)
        #expect(state.missing.isEmpty)
    }

    @Test func rowsCarryLastActivityAtAndANullStaysNil() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        try fx.sql("UPDATE sessions SET last_activity_at = '2026-01-01 10:05:00' WHERE agent_id = 'alpha'")
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let state = try loaded(reader.read())
        #expect(state.rows.first { $0.agentId == "alpha" }?.lastActivityAt == "2026-01-01 10:05:00")
        #expect(state.rows.filter { $0.agentId != "alpha" }.allSatisfy { $0.lastActivityAt == nil })
    }

    @Test func aDatabaseWithoutTheLastActivityColumnStillLoads() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        try fx.sql("ALTER TABLE sessions DROP COLUMN last_activity_at")
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let state = try loaded(reader.read())
        #expect(state.rows.count == 4 && state.rows.allSatisfy { $0.lastActivityAt == nil })
    }

    @Test func oldSchemaGivesNilNodeInfoColumnsAndTheSameMissingList() throws {
        let fx = try FixtureProject.make(schema: "old-schema")
        defer { fx.remove() }
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let state = try loaded(reader.read())
        #expect(state.rows.allSatisfy { $0.claudeSessionId == nil && $0.model == nil && $0.effort == nil })
        #expect(state.missing == ["task_title", "last_event"])
    }

    @Test func rowsAndTheInboxReadCarryTheStoredSessionPaths() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let state = try loaded(reader.read())
        let alpha = try #require(state.rows.first { $0.agentId == "alpha" })
        #expect(alpha.inboxPath == "/fx/sessions/alpha.in.jsonl" && alpha.outPath == "/fx/sessions/alpha.out.jsonl")
        #expect(alpha.createdAt == "2026-01-01 10:01:00")
        #expect(state.rows.first { $0.agentId == "bravo" }?.inboxPath == nil)
        #expect(state.dashboardInboxPath == "/fx/sessions/dashboard.in.jsonl")
        #expect(state.dashboardOutPath == "/fx/sessions/dashboard.out.jsonl")
        #expect(!state.rows.contains { $0.agentId == "dashboard" })
        #expect(state.missing.isEmpty)
        #expect(reader.inboxPath(of: "alpha") == "/fx/sessions/alpha.in.jsonl")
        #expect(reader.inboxPath(of: "dashboard") == "/fx/sessions/dashboard.in.jsonl")
        #expect(reader.inboxPath(of: "bravo") == nil)
        #expect(reader.inboxPath(of: "nobody") == nil)
    }

    @Test func aRootSessionReadsTheDashboardLogsUnderTheHomeFolder() {
        let paths = WorkerState.rootDashboardPaths(home: "/h")
        #expect(paths.inbox == "/h/.claude/sessions/dashboard/inbox.jsonl")
        #expect(paths.out == "/h/.claude/sessions/dashboard/out.jsonl")
    }

    @Test func oldSchemaGivesNilSessionPathsAndTheSameMissingList() throws {
        let fx = try FixtureProject.make(schema: "old-schema")
        defer { fx.remove() }
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let state = try loaded(reader.read())
        #expect(state.rows.allSatisfy { $0.inboxPath == nil && $0.outPath == nil })
        #expect(state.dashboardInboxPath == nil && state.dashboardOutPath == nil)
        #expect(state.missing == ["task_title", "last_event"])
        #expect(reader.inboxPath(of: "dashboard") == nil)
    }

    @Test func projectWithoutClaudeFolderGivesNoDatabaseAndCreatesNothing() throws {
        let fx = try FixtureProject.make(withDatabase: false)
        defer { fx.remove() }
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        #expect(reader.read() == .noDatabase)
        #expect(!WorkerFiles.exists(fx.path + "/.claude"))
    }

    @Test func readingLeavesTheFileBytesAndDumpUnchanged() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        // With -wal and -shm present (the fixture script leaves them).
        #expect(WorkerFiles.exists(fx.dbPath + "-wal") && WorkerFiles.exists(fx.dbPath + "-shm"))
        let bytesWithSidecars = WorkerFiles.bytes(fx.dbPath), dumpWithSidecars = WorkerFiles.dump(fx.dbPath)
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        _ = try loaded(reader.read())
        _ = try loaded(reader.read())
        #expect(WorkerFiles.bytes(fx.dbPath) == bytesWithSidecars)
        #expect(WorkerFiles.dump(fx.dbPath) == dumpWithSidecars)
        reader.close()

        // Idle: no sidecars.
        WorkerFiles.removeSidecars(fx.dbPath)
        let idleBytes = WorkerFiles.bytes(fx.dbPath)
        _ = try loaded(reader.read())
        #expect(WorkerFiles.bytes(fx.dbPath) == idleBytes)
        #expect(WorkerFiles.dump(fx.dbPath) == dumpWithSidecars)
    }

    @Test func idleFixtureWithoutSidecarsReadsThroughTheFallbackAndLeavesNone() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        WorkerFiles.removeSidecars(fx.dbPath)
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let state = try loaded(reader.read())
        #expect(state.rows.map(\.agentId) == order)
        #expect(!WorkerFiles.exists(fx.dbPath + "-wal"))
        #expect(!WorkerFiles.exists(fx.dbPath + "-shm"))
        // A second read, still idle, behaves the same.
        _ = try loaded(reader.read())
        #expect(!WorkerFiles.exists(fx.dbPath + "-wal") && !WorkerFiles.exists(fx.dbPath + "-shm"))
    }

    @Test func idleFixtureWithoutSidecarsGivesTheStoredInboxPathAndLeavesNone() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        WorkerFiles.removeSidecars(fx.dbPath)
        let reader = WorkerDatabase(project: fx.path)
        #expect(reader.inboxPath(of: "dashboard") == "/fx/sessions/dashboard.in.jsonl")
        #expect(reader.inboxPath(of: "alpha") == "/fx/sessions/alpha.in.jsonl")
        #expect(!WorkerFiles.exists(fx.dbPath + "-wal"))
        #expect(!WorkerFiles.exists(fx.dbPath + "-shm"))
    }

    @Test func readerSeesARowThatIsNotCheckpointedYet() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        var writer: OpaquePointer?
        #expect(sqlite3_open_v2(fx.dbPath, &writer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        sqlite3_exec(writer, "PRAGMA wal_autocheckpoint=0", nil, nil, nil)
        let insert = "INSERT INTO sessions (agent_id, worktree_path, status, created_at) VALUES ('echo','/fx/echo','running','2026-01-01 10:05:00')"
        #expect(sqlite3_exec(writer, insert, nil, nil, nil) == SQLITE_OK)
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let state = try loaded(reader.read())
        #expect(state.rows.map(\.agentId) == order + ["echo"])
    }

    @Test func nextReadShowsNewContentAfterTheFileIsReplaced() throws {
        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        let first = try loaded(reader.read())
        #expect(first.missing.isEmpty)

        try FileManager.default.removeItem(atPath: fx.dbPath)
        WorkerFiles.removeSidecars(fx.dbPath)
        try fx.write(schema: "old-schema")
        let second = try loaded(reader.read())
        #expect(second.missing == ["task_title", "last_event"])
    }

    @Test func folderNameWithSpaceAndHashReadsThroughBothPaths() throws {
        let fx = try FixtureProject.make(name: "my proj #1 %20?")
        defer { fx.remove() }
        let withSidecars = WorkerDatabase(project: fx.path)
        defer { withSidecars.close() }
        #expect(try loaded(withSidecars.read()).rows.map(\.agentId) == order)
        withSidecars.close()

        WorkerFiles.removeSidecars(fx.dbPath)
        #expect(try loaded(withSidecars.read()).rows.map(\.agentId) == order)
        #expect(!WorkerFiles.exists(fx.dbPath + "-wal"))
    }

    @Test func errnoMappingAndUnreadableFile() throws {
        #expect(WorkerDatabase.classify(errno: EPERM) == .permissionDenied)
        #expect(WorkerDatabase.classify(errno: EACCES) == .permissionDenied)
        #expect(WorkerDatabase.classify(errno: ENOENT) == .noDatabase)
        #expect(WorkerDatabase.classify(errno: ENOTDIR) == .noDatabase)
        if case .failed = WorkerDatabase.classify(errno: EIO) {} else { Issue.record("EIO should fail") }

        let fx = try FixtureProject.make()
        defer { fx.remove() }
        let reader = WorkerDatabase(project: fx.path)
        defer { reader.close() }
        _ = try loaded(reader.read())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fx.dbPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fx.dbPath) }
        #expect(reader.read() == .permissionDenied)
    }
}
