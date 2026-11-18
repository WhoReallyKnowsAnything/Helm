import Foundation

struct NotionTask: Equatable, Identifiable {
    let id: String
    let title: String
    let status: String
    let priority: String?
    let tags: [String]
    let url: String?
    let parentID: String?
}

struct TaskList: Equatable {
    let schema: Int
    let project: String
    let generatedAt: Date
    let tasks: [NotionTask]
}

/// One top-level row and the tasks that hang under it, as indices into `TaskList.tasks`.
struct TaskGroup: Equatable {
    let root: Int
    let children: [Int]
}

/// Pure derivations for the sheet (D-14).
extension TaskList {
    /// A task is a child when its `parent_id` names another listed task, and sits under the root of its parent chain.
    /// Every other task is a root: no parent, a parent that is not listed, or a parent chain that loops. Each task
    /// appears exactly once, in file order.
    var groups: [TaskGroup] {
        var firstIndex: [String: Int] = [:]
        for (index, task) in tasks.enumerated() where firstIndex[task.id] == nil { firstIndex[task.id] = index }
        func rootOf(_ start: Int) -> Int? {
            var seen: Set<Int> = [start]
            var current = start
            while let parent = tasks[current].parentID.flatMap({ firstIndex[$0] }) {
                if !seen.insert(parent).inserted { return nil }
                current = parent
            }
            return current
        }
        var children: [Int: [Int]] = [:]
        var roots: [Int] = []
        for index in tasks.indices {
            if let root = rootOf(index), root != index { children[root, default: []].append(index) } else { roots.append(index) }
        }
        return roots.map { TaskGroup(root: $0, children: children[$0] ?? []) }
    }

    /// Titles that two or more tasks share. The orchestrator matches a pick by exact string, so it cannot tell them apart.
    var duplicateTitles: Set<String> {
        var seen: Set<String> = [], twice: Set<String> = []
        for task in tasks where !seen.insert(task.title).inserted { twice.insert(task.title) }
        return twice
    }

    /// "5 seconds", "3 minutes", "2 hours" or "3 days": the whole units of the larger step. A future date reads as 0 seconds.
    func ageText(now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(generatedAt)))
        let (count, unit) = switch seconds {
        case ..<60: (seconds, "second")
        case ..<3600: (seconds / 60, "minute")
        case ..<86400: (seconds / 3600, "hour")
        default: (seconds / 86400, "day")
        }
        return "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}

enum TaskListRead: Equatable {
    case list(TaskList)
    /// One line for the sheet.
    case failed(String)
}

/// Reads `<project>/.claude/notion-tasks.json` (D-12, D-13), written by the orchestrator. The app never creates,
/// renames or deletes it. The text of the file is untrusted: only its shape is checked.
enum TaskListFile {
    static let name = "notion-tasks.json"

    static func path(of project: String) -> String { project + "/.claude/" + name }

    static func read(project: String) -> TaskListRead {
        let path = path(of: project)
        guard let data = GateHoldReader.readRegularFile(path) else { return .failed(whyUnreadable(path)) }
        return parse(data)
    }

    /// Pure. Never crashes on any input.
    static func parse(_ data: Data) -> TaskListRead {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return .failed("\(name) is empty.")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failed("\(name) is not valid JSON.")
        }
        guard let schema = root["schema"] as? Int else { return wrongType("schema") }
        guard let project = root["project"] as? String else { return wrongType("project") }
        guard let generated = root["generated_at"] as? String else { return wrongType("generated_at") }
        guard let generatedAt = ISO8601DateFormatter().date(from: generated) else {
            return .failed("\(name): generated_at is not a valid date.")
        }
        guard let rows = root["tasks"] as? [Any] else { return wrongType("tasks") }
        var tasks: [NotionTask] = []
        for row in rows {
            guard let fields = row as? [String: Any] else { return wrongType("tasks") }
            guard let id = fields["id"] as? String else { return wrongType("tasks.id") }
            guard let title = fields["title"] as? String else { return wrongType("tasks.title") }
            guard let status = fields["status"] as? String else { return wrongType("tasks.status") }
            for key in ["priority", "parent_id", "url"] where !isTextOrAbsent(fields[key]) {
                return wrongType("tasks.\(key)")
            }
            let tags: [String]
            switch fields["tags"] {
            case nil, is NSNull: tags = []
            case let list as [String]: tags = list
            default: return wrongType("tasks.tags")
            }
            tasks.append(NotionTask(
                id: id, title: title, status: status, priority: fields["priority"] as? String, tags: tags,
                url: fields["url"] as? String, parentID: fields["parent_id"] as? String))
        }
        return .list(TaskList(schema: schema, project: project, generatedAt: generatedAt, tasks: tasks))
    }

    private static func wrongType(_ key: String) -> TaskListRead {
        .failed("\(name): \"\(key)\" is missing or has the wrong type.")
    }

    private static func isTextOrAbsent(_ value: Any?) -> Bool { value == nil || value is NSNull || value is String }

    private static func whyUnreadable(_ path: String) -> String {
        var info = stat()
        if lstat(path, &info) != 0 {
            return errno == ENOENT || errno == ENOTDIR ? "\(name) was not found." : "\(name) cannot be read."
        }
        if (info.st_mode & S_IFMT) == S_IFREG, info.st_size > GateHoldReader.maxFileBytes {
            return "\(name) is larger than 1 MiB."
        }
        return "\(name) cannot be read (it must be a regular file)."
    }
}
