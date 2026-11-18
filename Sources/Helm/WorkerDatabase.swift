import Foundation
import SQLite3

/// One `sessions` row other than the orchestrator's `dashboard` row. `status` is the raw text (D-11).
struct WorkerRow: Equatable {
    let agentId: String
    let status: String
    let taskTitle: String?
    let lastEvent: String?
    /// Match keys and fallback text for the node info (INFO-02). Not in `WorkerState.missing`: a database without them is normal.
    var worktreePath: String? = nil
    var claudeSessionId: String? = nil
    var model: String? = nil
    var effort: String? = nil
    /// The text the orchestrator last stamped on the row. The gate stamps it when it records `blocked`, so it tells one block from the next.
    var lastActivityAt: String? = nil
    /// The stream-json inbox and out-log paths the orchestrator stored for this session. Nil on a database without the columns.
    var inboxPath: String? = nil
    var outPath: String? = nil
    /// The row's `created_at` text. Lets the board tell a starting worker from a dead one.
    var createdAt: String? = nil
}

/// One `dependencies` row: `dependent` waits on `upstream` (D-15).
struct WorkerDependency: Equatable {
    let dependent: String
    let upstream: String
}

struct WorkerState: Equatable {
    var rows: [WorkerRow] = []
    var dependencies: [WorkerDependency] = []
    /// Optional columns or tables the database lacks (D-12), by name.
    var missing: [String] = []
    /// The orchestrator's own `dashboard` row paths (D-08). Not in `rows`; nil on a database without the columns or the row.
    var dashboardInboxPath: String? = nil
    var dashboardOutPath: String? = nil

    /// A root session starts without a state store, so its dashboard logs sit in `~/.claude/sessions/dashboard`.
    static func rootDashboardPaths(home: String = NSHomeDirectory()) -> (inbox: String, out: String) {
        (home + "/.claude/sessions/dashboard/inbox.jsonl", home + "/.claude/sessions/dashboard/out.jsonl")
    }
}

enum WorkerRead: Equatable {
    case loaded(WorkerState)
    /// No database file for the project.
    case noDatabase
    /// A database without a usable `sessions` table.
    case noState
    /// macOS reports a missing Documents grant as EPERM (D-10).
    case permissionDenied
    case failed(String)
}

/// What the store reads from. The real one is `WorkerDatabase`; tests inject fakes.
/// Every call comes from one serial queue, so an implementation needs no locking.
protocol WorkerSource: AnyObject, Sendable {
    func read() -> WorkerRead
    func close()
}

/// Reads `<project>/.claude/session-state.db` and nothing else (D-01, D-11, D-12, D-13).
/// It never creates, writes or deletes a file. It owns one connection and is not thread-safe by
/// design: the caller serializes every call on one queue.
final class WorkerDatabase: WorkerSource, @unchecked Sendable {
    /// This reader's own busy timeout.
    static let busyTimeoutMs: Int32 = 2000

    enum Access: Equatable {
        case readable, noDatabase, permissionDenied, failed(String)
    }

    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
    }

    private struct SQLiteFailure: Error {
        let code: Int32
        let message: String
    }

    private let path: String
    private var connection: OpaquePointer?
    private var identity: FileIdentity?

    init(project: String) {
        path = project + "/.claude/session-state.db"
    }

    deinit { close() }

    /// The errno of the `open(2)` probe, as a case. A pure function, because no test can provoke EPERM.
    static func classify(errno code: Int32) -> Access {
        switch code {
        case ENOENT, ENOTDIR: return .noDatabase
        case EPERM, EACCES: return .permissionDenied
        default: return .failed(String(cString: strerror(code)))
        }
    }

    func close() {
        if let connection { sqlite3_close(connection) }
        connection = nil
        identity = nil
    }

    func read() -> WorkerRead {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else {
            let code = errno  // close() calls into SQLite, which can overwrite errno
            close()
            switch Self.classify(errno: code) {
            case .noDatabase: return .noDatabase
            case .permissionDenied: return .permissionDenied
            case .failed(let text): return .failed(text)
            case .readable: return .failed("unreachable")
            }
        }
        var info = stat()
        let statted = fstat(fd, &info) == 0
        let statErrno = errno
        Darwin.close(fd)
        guard statted else { return .failed(String(cString: strerror(statErrno))) }
        let current = FileIdentity(device: info.st_dev, inode: info.st_ino)

        // teardown and re-init replace the file; a held handle would keep reading the deleted one.
        if connection != nil, identity != current { close() }
        do {
            if connection == nil { connection = try Self.open(path, flags: SQLITE_OPEN_READONLY) }
            identity = current
            return try Self.load(connection!)
        } catch let failure as SQLiteFailure {
            let canFallBack = failure.code == SQLITE_CANTOPEN && !FileManager.default.fileExists(atPath: path + "-wal")
            close()
            guard canFallBack else { return .failed("SQLite error \(failure.code): \(failure.message)") }
            return immutableRead()
        } catch {
            close()
            return .failed("\(error)")
        }
    }

    /// The stored inbox path of one session, including `dashboard` (which `read()` leaves out). Nil when the
    /// database, column, row or value is absent. Opens its own read-only connection and keeps nothing open.
    func inboxPath(of agentId: String) -> String? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")) ?? path
        let quoted = agentId.replacingOccurrences(of: "'", with: "''")
        func lookup(_ handle: OpaquePointer) throws -> String? {
            let columns = try Self.query(handle, "PRAGMA table_info(sessions)") { Self.text($0, 1) ?? "" }
            guard columns.contains("inbox_path") else { return nil }
            let found = try Self.query(handle, "SELECT inbox_path FROM sessions WHERE agent_id = '\(quoted)'") { Self.text($0, 0) }
            return found.first ?? nil
        }
        // A plain open succeeds lazily; on an idle WAL database the first statement fails with CANTOPEN.
        if let handle = try? Self.open(path, flags: SQLITE_OPEN_READONLY) {
            defer { sqlite3_close(handle) }
            do { return try lookup(handle) } catch let failure as SQLiteFailure {
                guard failure.code == SQLITE_CANTOPEN, !FileManager.default.fileExists(atPath: path + "-wal") else { return nil }
            } catch { return nil }
        }
        guard let handle = try? Self.open("file:\(encoded)?immutable=1", flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI) else { return nil }
        defer { sqlite3_close(handle) }
        return try? lookup(handle)
    }

    /// An idle WAL database has no `-wal` and no `-shm`, and a plain read-only connection cannot open it.
    /// `immutable=1` always opens but ignores the WAL, which is fine because there is none. Keeps nothing open.
    private func immutableRead() -> WorkerRead {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        do {
            let handle = try Self.open("file:\(encoded)?immutable=1", flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
            defer { sqlite3_close(handle) }
            return try Self.load(handle)
        } catch let failure as SQLiteFailure {
            return .failed("SQLite error \(failure.code): \(failure.message)")
        } catch {
            return .failed("\(error)")
        }
    }

    private static func open(_ name: String, flags: Int32) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(name, &handle, flags, nil) == SQLITE_OK, let handle else {
            let failure = SQLiteFailure(code: handle.map { sqlite3_errcode($0) & 0xFF } ?? SQLITE_CANTOPEN,
                                        message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close(handle)
            throw failure
        }
        sqlite3_busy_timeout(handle, busyTimeoutMs)
        return handle
    }

    /// The first statement is the `table_info` pragma: it is where a plain connection reports CANTOPEN.
    private static func load(_ handle: OpaquePointer) throws -> WorkerRead {
        let sessionColumns = Set(try query(handle, "PRAGMA table_info(sessions)") { text($0, 1) ?? "" })
        guard sessionColumns.isSuperset(of: ["agent_id", "status", "created_at"]) else { return .noState }

        var missing: [String] = []
        func optional(_ column: String) -> String {
            if sessionColumns.contains(column) { return column }
            missing.append(column)
            return "NULL"
        }
        let title = optional("task_title"), event = optional("last_event")
        func extra(_ column: String) -> String { sessionColumns.contains(column) ? column : "NULL" }
        let rows = try query(handle, """
            SELECT agent_id, status, \(title), \(event), \(extra("worktree_path")), \(extra("claude_session_id")), \
            \(extra("model")), \(extra("effort")), \(extra("last_activity_at")), \(extra("inbox_path")), \(extra("out_path")), created_at FROM sessions \
            WHERE agent_id <> 'dashboard' ORDER BY created_at, agent_id
            """) {
            WorkerRow(agentId: text($0, 0) ?? "", status: text($0, 1) ?? "", taskTitle: text($0, 2), lastEvent: text($0, 3),
                      worktreePath: text($0, 4), claudeSessionId: text($0, 5), model: text($0, 6), effort: text($0, 7),
                      lastActivityAt: text($0, 8), inboxPath: text($0, 9), outPath: text($0, 10), createdAt: text($0, 11))
        }

        let dashboard = try query(handle, "SELECT \(extra("inbox_path")), \(extra("out_path")) FROM sessions WHERE agent_id = 'dashboard'") {
            (text($0, 0), text($0, 1))
        }.first

        let dependencyColumns = Set(try query(handle, "PRAGMA table_info(dependencies)") { text($0, 1) ?? "" })
        var dependencies: [WorkerDependency] = []
        if dependencyColumns.isSuperset(of: ["dependent_agent_id", "upstream_agent_id"]) {
            dependencies = try query(handle, "SELECT dependent_agent_id, upstream_agent_id FROM dependencies ORDER BY 1, 2") {
                WorkerDependency(dependent: text($0, 0) ?? "", upstream: text($0, 1) ?? "")
            }
        } else {
            missing.append("dependencies")
        }
        return .loaded(WorkerState(rows: rows, dependencies: dependencies, missing: missing,
                                   dashboardInboxPath: dashboard?.0, dashboardOutPath: dashboard?.1))
    }

    /// Finalizes the statement before it returns, so no read transaction stays open.
    private static func query<T>(_ handle: OpaquePointer, _ sql: String, _ map: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteFailure(code: sqlite3_errcode(handle) & 0xFF, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            result.append(map(statement))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else {
            throw SQLiteFailure(code: sqlite3_errcode(handle) & 0xFF, message: String(cString: sqlite3_errmsg(handle)))
        }
        return result
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
