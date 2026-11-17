import Foundation
import Testing
@testable import OrchestratorGUI

@MainActor
struct OpenProjectLogsTests {
    /// A fixture project whose dashboard and alpha out logs carry `tag`, so two projects give different paths.
    private func project(_ tag: String, schema: String = "") throws -> FixtureProject {
        let fx = try FixtureProject.make(schema: schema)
        if schema.isEmpty {
            try fx.sql("UPDATE sessions SET out_path = '/fx/\(tag)/' || agent_id || '.out.jsonl' WHERE out_path IS NOT NULL;")
        }
        return fx
    }

    private func wait(_ logs: OpenProjectLogs, until done: (Set<String>) -> Bool) async -> Set<String> {
        for _ in 0..<200 where !done(logs.paths) { try? await Task.sleep(for: .milliseconds(25)) }
        return logs.paths
    }

    @Test func twoProjectsGiveTheUnionOfTheirPathsIncludingTheDashboards() async throws {
        let a = try project("a"), b = try project("b")
        defer { a.remove(); b.remove() }
        let logs = OpenProjectLogs()
        logs.follow([a.path, b.path])
        let paths = await wait(logs) { $0.count == 4 }
        #expect(paths == ["/fx/a/dashboard.out.jsonl", "/fx/a/alpha.out.jsonl",
                          "/fx/b/dashboard.out.jsonl", "/fx/b/alpha.out.jsonl"])
    }

    @Test func aProjectWithoutTheColumnsGivesNoPathsAndNoFailure() async throws {
        let old = try project("old", schema: "old-schema")
        defer { old.remove() }
        let logs = OpenProjectLogs()
        logs.follow([old.path])
        try? await Task.sleep(for: .milliseconds(300))
        #expect(logs.paths.isEmpty)
    }

    @Test func aFolderThatLeftDropsItsPaths() async throws {
        let a = try project("a"), b = try project("b")
        defer { a.remove(); b.remove() }
        let logs = OpenProjectLogs()
        logs.follow([a.path, b.path])
        _ = await wait(logs) { $0.count == 4 }
        logs.follow([a.path])
        #expect(logs.paths == ["/fx/a/dashboard.out.jsonl", "/fx/a/alpha.out.jsonl"])
    }

    @Test func aRowAddedToADatabaseAppearsWithoutARestart() async throws {
        let a = try project("a")
        defer { a.remove() }
        let logs = OpenProjectLogs()
        logs.follow([a.path])
        _ = await wait(logs) { $0.count == 2 }
        try a.sql("INSERT INTO sessions (agent_id, worktree_path, status, created_at, out_path) VALUES ('echo', '/fx/echo', 'running', '2026-01-01 10:09:00', '/fx/a/echo.out.jsonl');")
        let paths = await wait(logs) { $0.contains("/fx/a/echo.out.jsonl") }
        #expect(paths.contains("/fx/a/echo.out.jsonl"))
    }
}
