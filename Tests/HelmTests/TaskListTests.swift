import Foundation
import Testing
@testable import Helm

struct TaskListTests {
    /// The shape `dispatch-task.sh --write-notion-tasks` writes, plus an unknown field.
    static let valid = """
    {"schema":1,"project":"demo","generated_at":"2026-11-01T10:00:00Z","extra":true,"tasks":[
     {"id":"t1","title":"Fix login","status":"Not started","priority":"High","tags":["a","b"],"url":"https://x/1","parent_id":null,"unknown":1},
     {"id":"t2","title":"Wave 1","status":"In progress","priority":null,"tags":[],"url":"https://x/2","parent_id":"t1"}
    ]}
    """

    private func failure(_ json: String) -> String? {
        if case .failed(let text) = TaskListFile.parse(Data(json.utf8)) { return text }
        return nil
    }

    private func project() throws -> String {
        let dir = NSTemporaryDirectory() + "task-list-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/.claude", withIntermediateDirectories: true)
        return dir
    }

    @Test func parsesEveryField() throws {
        guard case .list(let list) = TaskListFile.parse(Data(Self.valid.utf8)) else {
            Issue.record("expected a list"); return
        }
        #expect(list.schema == 1)
        #expect(list.project == "demo")
        #expect(list.generatedAt == ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        #expect(list.tasks.count == 2)
        #expect(list.tasks[0] == NotionTask(
            id: "t1", title: "Fix login", status: "Not started", priority: "High", tags: ["a", "b"],
            url: "https://x/1", parentID: nil))
        #expect(list.tasks[1] == NotionTask(
            id: "t2", title: "Wave 1", status: "In progress", priority: nil, tags: [],
            url: "https://x/2", parentID: "t1"))
    }

    @Test func eachFailureHasItsOwnText() {
        let texts = [
            failure(""), failure("  \n"), failure("{"), failure("[]"),
            failure(#"{"project":"p","generated_at":"2026-11-01T10:00:00Z","tasks":[]}"#),
            failure(#"{"schema":"1","project":"p","generated_at":"2026-11-01T10:00:00Z","tasks":[]}"#),
            failure(#"{"schema":1,"project":"p","generated_at":"yesterday","tasks":[]}"#),
            failure(#"{"schema":1,"project":"p","generated_at":"2026-11-01T10:00:00Z","tasks":{}}"#),
            failure(#"{"schema":1,"project":"p","generated_at":"2026-11-01T10:00:00Z","tasks":[{"id":"a","title":1,"status":"s"}]}"#),
            failure(#"{"schema":1,"project":"p","generated_at":"2026-11-01T10:00:00Z","tasks":[{"id":"a","title":"t","status":"s","tags":[1]}]}"#),
        ]
        #expect(!texts.contains(nil))
        let distinct = Set(texts.compactMap { $0 })
        // Same text for: empty and whitespace; "{" and "[]"; a missing and a wrongly typed "schema".
        // 7 different problems remain: empty, invalid JSON, schema, date, tasks, title, tags.
        #expect(distinct.count == 7)
    }

    @Test func aMissingFileFailsAndCreatesNothing() throws {
        let dir = try project()
        #expect(TaskListFile.read(project: dir) == .failed("notion-tasks.json was not found."))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir + "/.claude").isEmpty)
    }

    @Test func readsAFileOnDisk() throws {
        let dir = try project()
        try Self.valid.write(toFile: TaskListFile.path(of: dir), atomically: true, encoding: .utf8)
        guard case .list(let list) = TaskListFile.read(project: dir) else { Issue.record("expected a list"); return }
        #expect(list.tasks.count == 2)
    }

    @Test func aFileOverTheCapFails() throws {
        let dir = try project()
        let data = Data(repeating: 0x20, count: GateHoldReader.maxFileBytes + 1)
        FileManager.default.createFile(atPath: TaskListFile.path(of: dir), contents: data)
        #expect(TaskListFile.read(project: dir) == .failed("notion-tasks.json is larger than 1 MiB."))
    }

    @Test func aSymlinkFails() throws {
        let dir = try project()
        let real = dir + "/real.json"
        try Self.valid.write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: TaskListFile.path(of: dir), withDestinationPath: real)
        guard case .failed = TaskListFile.read(project: dir) else { Issue.record("expected a failure"); return }
    }

    // MARK: derivations (D-14)

    private static let generated = ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z")!

    private func list(_ rows: [(id: String, title: String, parent: String?)], generatedAt: Date = generated) -> TaskList {
        TaskList(schema: 1, project: "demo", generatedAt: generatedAt, tasks: rows.map {
            NotionTask(id: $0.id, title: $0.title, status: "Not started", priority: nil, tags: [], url: nil, parentID: $0.parent)
        })
    }

    @Test func aParentWithTwoChildrenIsOneRootAndTwoChildren() {
        let groups = list([("a", "A", nil), ("b", "B", "a"), ("c", "C", "a")]).groups
        #expect(groups == [TaskGroup(root: 0, children: [1, 2])])
    }

    @Test func aChildWhoseParentIsMissingBecomesARoot() {
        let groups = list([("a", "A", nil), ("b", "B", "gone")]).groups
        #expect(groups == [TaskGroup(root: 0, children: []), TaskGroup(root: 1, children: [])])
    }

    @Test func twoTasksThatNameEachOtherAreBothListedOnce() {
        let groups = list([("a", "A", "b"), ("b", "B", "a"), ("c", "C", "a")]).groups
        #expect(groups.map(\.root) == [0, 1, 2])
        #expect(groups.allSatisfy { $0.children.isEmpty })
    }

    @Test func aTaskThatNamesItselfIsListedOnceAsARoot() {
        #expect(list([("a", "A", "a")]).groups == [TaskGroup(root: 0, children: [])])
    }

    @Test func aGrandchildSitsUnderTheRootInFileOrder() {
        let groups = list([("a", "A", nil), ("c", "C", "b"), ("b", "B", "a")]).groups
        #expect(groups == [TaskGroup(root: 0, children: [1, 2])])
    }

    @Test func tasksWithTheSameTitleAreFlaggedAndAThirdIsNot() {
        let flagged = list([("a", "Same", nil), ("b", "Same", nil), ("c", "Other", nil), ("d", "same", nil)]).duplicateTitles
        #expect(flagged == ["Same"])
    }

    @Test(arguments: [(5, "5 seconds"), (1, "1 second"), (180, "3 minutes"), (7200, "2 hours"), (259_200, "3 days"), (-30, "0 seconds")])
    func theAgeOfTheFileReadsInTheLargestWholeUnit(seconds: Int, text: String) {
        #expect(list([], generatedAt: Self.generated).ageText(now: Self.generated.addingTimeInterval(TimeInterval(seconds))) == text)
    }
}
