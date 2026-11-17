import Foundation
import Testing
@testable import OrchestratorGUI

@Suite @MainActor struct OpenProjectsTests {
    private let file: URL

    init() {
        file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-projects-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("open-projects.json")
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func snapshot(
        rows: [SessionRow] = [SessionRow(id: "a", title: "A"), SessionRow(id: "b", title: "B")],
        windows: [WindowEntry]? = nil
    ) -> TmuxSnapshot {
        TmuxSnapshot(
            sessions: [],
            windows: windows ?? [
                WindowEntry(session: "a", name: "dashboard", path: "/work/a", activity: nil, paneId: "%1"),
                WindowEntry(session: "a", name: "w1", path: "/work/a", activity: nil, paneId: "%2"),
                WindowEntry(session: "b", name: "dashboard", path: "/work/b", activity: nil, paneId: "%3"),
            ],
            rows: rows)
    }

    @Test func missingFileListsNothing() {
        defer { cleanUp() }
        #expect(OpenProjects(file: file).records.isEmpty)
    }

    @Test func recordingWritesTheFileAndASecondStoreListsIt() {
        defer { cleanUp() }
        let first = OpenProjects(file: file)
        first.record(snapshot())
        #expect(first.records == [
            OpenProject(id: "a", title: "A", folder: "/work/a"),
            OpenProject(id: "b", title: "B", folder: "/work/b"),
        ])
        #expect(OpenProjects(file: file).records == first.records)
    }

    @Test func recordingTheSameSnapshotAgainWritesNothing() {
        defer { cleanUp() }
        let store = OpenProjects(file: file)
        store.record(snapshot())
        let writes = store.writeCount
        #expect(writes == 1)
        store.record(snapshot())
        #expect(store.writeCount == writes)
        #expect(store.records.count == 2)
    }

    @Test func aChangedTitleUpdatesTheRecordInPlace() {
        defer { cleanUp() }
        let store = OpenProjects(file: file)
        store.record(snapshot())
        store.record(snapshot(rows: [SessionRow(id: "a", title: "A2"), SessionRow(id: "b", title: "B")]))
        #expect(store.records.map(\.title) == ["A2", "B"])
        #expect(store.records.map(\.id) == ["a", "b"])
        #expect(OpenProjects(file: file).records.map(\.title) == ["A2", "B"])
    }

    @Test func rootNoDashboardAndEmptyFolderRowsAreNotRecorded() {
        defer { cleanUp() }
        let store = OpenProjects(file: file)
        store.record(snapshot(
            rows: [
                SessionRow(id: "root", title: "Home", isRootSession: true),
                SessionRow(id: "nodash", title: "N"),
                SessionRow(id: "empty", title: "E"),
            ],
            windows: [
                WindowEntry(session: "root", name: "dashboard", path: "/Users/x", activity: nil, paneId: "%1"),
                WindowEntry(session: "nodash", name: "w1", path: "/work/n", activity: nil, paneId: "%2"),
                WindowEntry(session: "empty", name: "dashboard", path: "", activity: nil, paneId: "%3"),
            ]))
        #expect(store.records.isEmpty)
        #expect(store.writeCount == 0)
    }

    @Test func dormantIsTheRecordsThatAreNotLiveInFirstSeenOrder() {
        defer { cleanUp() }
        let store = OpenProjects(file: file)
        store.record(snapshot())
        #expect(store.dormant(excluding: [SessionRow(id: "b", title: "B")]).map(\.id) == ["a"])
        #expect(store.dormant(excluding: []).map(\.id) == ["a", "b"])
        #expect(store.dormant(excluding: store.records.map { SessionRow(id: $0.id, title: $0.title) }).isEmpty)
    }

    @Test func removingDeletesFromFileAndListAndUnknownIdDoesNothing() {
        defer { cleanUp() }
        let store = OpenProjects(file: file)
        store.record(snapshot())
        let writes = store.writeCount
        store.remove("zzz")
        #expect(store.records.count == 2)
        #expect(store.writeCount == writes)
        store.remove("a")
        #expect(store.records.map(\.id) == ["b"])
        #expect(OpenProjects(file: file).records.map(\.id) == ["b"])
    }

    @Test func removingAllDormantIdsKeepsTheLiveRecordWithOneWrite() {
        defer { cleanUp() }
        let store = OpenProjects(file: file)
        store.record(snapshot(
            rows: [SessionRow(id: "a", title: "A"), SessionRow(id: "b", title: "B"), SessionRow(id: "c", title: "C")],
            windows: ["a", "b", "c"].map { WindowEntry(session: $0, name: "dashboard", path: "/work/\($0)", activity: nil, paneId: "%\($0)") }))
        let live = [SessionRow(id: "b", title: "B")]
        let writes = store.writeCount
        store.remove(["zzz", "yyy"])
        #expect(store.writeCount == writes)
        store.remove(store.dormant(excluding: live).map(\.id))
        #expect(store.records.map(\.id) == ["b"])
        #expect(store.writeCount == writes + 1)
        #expect(OpenProjects(file: file).records.map(\.id) == ["b"])
    }

    @Test func invalidJsonLoadsEmptyAndIsReplacedOnTheNextWrite() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        let store = OpenProjects(file: file)
        #expect(store.records.isEmpty)
        store.record(snapshot())
        #expect(OpenProjects(file: file).records.count == 2)
    }

    @Test func defaultFileSitsInTheSupportFolder() {
        #expect(OpenProjects.defaultFile.path.hasSuffix("Library/Application Support/OrchestratorGUI/open-projects.json"))
    }
}
