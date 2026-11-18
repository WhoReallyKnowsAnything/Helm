import Foundation
import Testing
@testable import Helm

@MainActor
@Suite(.serialized) struct TaskListStoreTests {
    private func json(_ titles: [String]) -> String {
        let tasks = titles.enumerated().map {
            #"{"id":"t\#($0.offset)","title":"\#($0.element)","status":"Not started","priority":null,"tags":[],"parent_id":null}"#
        }
        return #"{"schema":1,"project":"p","generated_at":"2026-11-01T10:00:00Z","tasks":[\#(tasks.joined(separator: ","))]}"#
    }

    private func project(_ text: String?) throws -> FixtureProject {
        let fx = try FixtureProject.make(withDatabase: false)
        try FileManager.default.createDirectory(atPath: fx.path + "/.claude", withIntermediateDirectories: true)
        if let text { try write(text, in: fx) }
        return fx
    }

    /// Like the orchestrator's writer: a temp file renamed onto the final name.
    private func write(_ text: String, in fx: FixtureProject) throws {
        let temp = fx.path + "/.claude/.notion-tasks.XyZ789"
        try text.write(toFile: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: TaskListFile.path(of: fx.path)), withItemAt: URL(fileURLWithPath: temp))
    }

    private func wait(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func aValidFileGivesAListAndEditsUpdateIt() async throws {
        let fx = try project(json(["One"]))
        defer { fx.remove() }
        let store = TaskListStore()
        store.point(at: fx.path)
        #expect(try await wait { store.list?.tasks.map(\.title) == ["One"] })
        #expect(store.failure == nil)
        try write(json(["One", "Two"]), in: fx)
        #expect(try await wait { store.list?.tasks.map(\.title) == ["One", "Two"] })
    }

    @Test func aBrokenFileKeepsTheListAndAGoodFileClearsTheFailure() async throws {
        let fx = try project(json(["One"]))
        defer { fx.remove() }
        let store = TaskListStore()
        store.point(at: fx.path)
        #expect(try await wait { store.list != nil })
        try write("{", in: fx)
        #expect(try await wait { store.failure != nil })
        #expect(store.list?.tasks.map(\.title) == ["One"])
        try write(json(["Three"]), in: fx)
        #expect(try await wait { store.failure == nil && store.list?.tasks.map(\.title) == ["Three"] })
    }

    @Test func deletingTheFileKeepsTheListAndSetsAFailure() async throws {
        let fx = try project(json(["One"]))
        defer { fx.remove() }
        let store = TaskListStore()
        store.point(at: fx.path)
        #expect(try await wait { store.list != nil })
        try FileManager.default.removeItem(atPath: TaskListFile.path(of: fx.path))
        #expect(try await wait { store.failure != nil })
        #expect(store.list?.tasks.map(\.title) == ["One"])
    }

    @Test func aFileThatWasNeverGoodShowsTheFailureAndNoList() async throws {
        let fx = try project("{")
        defer { fx.remove() }
        let store = TaskListStore()
        store.point(at: fx.path)
        #expect(try await wait { store.failure != nil })
        #expect(store.list == nil)
    }

    @Test func repointingClearsListAndFailure() async throws {
        let fx = try project(json(["One"]))
        let other = try project(nil)
        defer { fx.remove(); other.remove() }
        let store = TaskListStore()
        store.point(at: fx.path)
        #expect(try await wait { store.list != nil })
        store.point(at: other.path)
        #expect(store.list == nil)
        #expect(store.failure == nil)
        // The new folder has no file: only its own failure shows, never the old list.
        #expect(try await wait { store.failure != nil })
        #expect(store.list == nil)
    }
}
