import CoreServices
import Foundation

/// One FSEvents stream on `<project>/.claude` (D-02). It calls `onEvent` once per batch that touches
/// `session-state.db`, `-wal`, `-shm` or `-journal`, and ignores every other name. No timer. The stream
/// stops when the watcher is released. `init(folder:)` is the second way to build it: it watches one
/// existing folder and calls `onEvent` once per batch of events for any file in it (the status-line samples).
/// `init(holdsOf:)` is the third: the same stream, but only a `.pending` or `.decision` file inside `gate-holds`,
/// or the `gate-holds` folder itself, counts (D-14).
/// `init(taskListOf:)` is the fourth: only an event on exactly `notion-tasks.json` counts (D-12). The writer renames a
/// `.notion-tasks.XXXXXX` temp file onto that name, so the temp names never fire.
/// `init(planningOf:)` is the fifth: it watches the project root, so a `.planning` folder made later is seen, and only a
/// path under `.planning` counts, except `trace.jsonl` and `reads.jsonl`, and except anything under `.planning/records`
/// other than `state.json` (the board refresh, D-06, D-07). `phases/<N>/records` is not matched, so a plan review or plan report refreshes.
/// `init(uatIn:)` is the sixth: it watches one existing folder (`<worktree>/.planning/phases/<N>/`) and only an event on
/// exactly `UAT.md` counts. Cadence renames a temp file onto that name, so the temp names never fire.
/// `init(reportsIn:)` is the seventh: it watches the same phase folder, and only a `.md` file (no leading dot) inside
/// a `reports` folder at any depth under it (`records/reports` in Cadence 4.3), or such a `reports` folder itself,
/// counts, so a `reports` folder made later is seen.
/// `init(file:)` is the eighth: it watches the folder of one existing file, and only an event on exactly that resolved
/// path counts (the stream is recursive, so a same-named file deeper in the tree does not). A writer that renames a temp
/// file onto the name fires, and the temp names do not.
final class ProjectWatcher {
    private enum Filter {
        case database, anyFile, holds, taskList, uat, reports, gitLog
        /// Holds the resolved project root.
        case planning(String)
        /// Holds the resolved full path of the one file.
        case file(String)

        func accepts(_ path: String) -> Bool {
            let name = (path as NSString).lastPathComponent
            switch self {
            case .file(let full): return path == full
            case .planning(let root):
                guard path.hasPrefix(root + "/.planning/") else { return false }
                let records = root + "/.planning/records"
                if path == records || path.hasPrefix(records + "/") { return name == "state.json" }
                return name != "trace.jsonl" && name != "reads.jsonl"
            case .database: return name.hasPrefix(ProjectWatcher.databaseName)
            case .anyFile: return true
            case .uat: return name == "UAT.md"
            case .gitLog:
                return name == "HEAD" && ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent == "logs"
            case .reports:
                if name == "reports" { return true }
                let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return parent == "reports" && name.hasSuffix(".md") && !name.hasPrefix(".")
            case .taskList:
                return name == TaskListFile.name && ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent == ".claude"
            case .holds:
                if name == "gate-holds" { return true }
                let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return parent == "gate-holds" && !name.hasPrefix(".tmp.") && (name.hasSuffix(".pending") || name.hasSuffix(".decision"))
            }
        }
    }

    /// Owned by the stream context, so a callback that runs during teardown still has a live closure.
    private final class Box {
        let onEvent: @Sendable () -> Void
        let filter: Filter
        init(filter: Filter, _ onEvent: @escaping @Sendable () -> Void) {
            self.filter = filter
            self.onEvent = onEvent
        }
    }

    private static let databaseName = "session-state.db"
    private let queue = DispatchQueue(label: "ProjectWatcher")
    private var stream: FSEventStreamRef?

    convenience init(project: String, onEvent: @escaping @Sendable () -> Void) {
        let claude = Self.realPath(project) + "/.claude"
        // Worker checkouts live under worktrees; without this every file write in them reaches the callback.
        self.init(watching: claude, filter: .database, excluding: claude + "/worktrees", onEvent: onEvent)
    }

    convenience init(folder: String, onEvent: @escaping @Sendable () -> Void) {
        self.init(watching: Self.realPath(folder), filter: .anyFile, excluding: nil, onEvent: onEvent)
    }

    convenience init(holdsOf project: String, onEvent: @escaping @Sendable () -> Void) {
        let claude = Self.realPath(project) + "/.claude"
        self.init(watching: claude, filter: .holds, excluding: claude + "/worktrees", onEvent: onEvent)
    }

    convenience init(taskListOf project: String, onEvent: @escaping @Sendable () -> Void) {
        let claude = Self.realPath(project) + "/.claude"
        self.init(watching: claude, filter: .taskList, excluding: claude + "/worktrees", onEvent: onEvent)
    }

    convenience init(planningOf project: String, onEvent: @escaping @Sendable () -> Void) {
        let root = Self.realPath(project)
        self.init(watching: root, filter: .planning(root), excluding: root + "/.claude/worktrees", onEvent: onEvent)
    }

    convenience init(uatIn folder: String, onEvent: @escaping @Sendable () -> Void) {
        self.init(watching: Self.realPath(folder), filter: .uat, excluding: nil, onEvent: onEvent)
    }

    convenience init(file: String, onEvent: @escaping @Sendable () -> Void) {
        let url = URL(fileURLWithPath: file)
        let folder = Self.realPath(url.deletingLastPathComponent().path)
        self.init(watching: folder, filter: .file(folder + "/" + url.lastPathComponent), excluding: nil, onEvent: onEvent)
    }

    convenience init(reportsIn folder: String, onEvent: @escaping @Sendable () -> Void) {
        self.init(watching: Self.realPath(folder), filter: .reports, excluding: nil, onEvent: onEvent)
    }

    /// A linked worktree's own git folder; only an event on `logs/HEAD` counts, which every commit appends to.
    convenience init(gitLogIn gitDir: String, onEvent: @escaping @Sendable () -> Void) {
        self.init(watching: Self.realPath(gitDir), filter: .gitLog, excluding: nil, onEvent: onEvent)
    }

    /// FSEvents reports and matches real paths, so resolve symlinks of the folder (it exists). /var is one.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private init(watching path: String, filter: Filter, excluding: String?, onEvent: @escaping @Sendable () -> Void) {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(Box(filter: filter, onEvent)).toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Box>.fromOpaque(info).release() } },
            copyDescription: nil)
        // A C function pointer: it captures nothing and reads everything from `info`.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            guard paths.prefix(count).contains(where: box.filter.accepts) else { return }
            box.onEvent()
        }
        // CFTypes: without it the callback receives raw C strings and crashes when it reads them as an array.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let made = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                             FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        else {
            Unmanaged<Box>.fromOpaque(context.info!).release()
            return
        }
        if let excluding { FSEventStreamSetExclusionPaths(made, [excluding] as CFArray) }
        FSEventStreamSetDispatchQueue(made, queue)
        FSEventStreamStart(made)
        stream = made
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
