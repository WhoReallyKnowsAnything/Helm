import AppKit
import Foundation
import Testing
@testable import Helm

@MainActor
@Suite struct EditorStoreTests {
    private func settle(_ store: EditorStore) async {
        for _ in 0..<200 where store.result == nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func readableFilePublishesItsText() async {
        let store = EditorStore(loader: { _ in .text("let a = 1\n") })
        store.point(at: URL(fileURLWithPath: "/tmp/a.swift"))
        await settle(store)
        #expect(store.result == .text("let a = 1\n"))
    }

    @Test func oversizeFilePublishesTheReason() async {
        let store = EditorStore(loader: { EditorText.load($0, read: { _ in Data(repeating: 0x61, count: EditorText.maxBytes + 1) }) })
        store.point(at: URL(fileURLWithPath: "/tmp/big.log"))
        await settle(store)
        guard case .unsupported(let reason) = store.result else {
            Issue.record("expected an unsupported result")
            return
        }
        #expect(reason.contains("512 KB"))
    }

    @Test func pointingAtNothingClearsTheResult() async {
        let store = EditorStore(loader: { _ in .text("x") })
        store.point(at: URL(fileURLWithPath: "/tmp/a.swift"))
        await settle(store)
        store.point(at: nil)
        #expect(store.result == nil)
    }

    @Test func relativePathStripsTheProjectFolderOnly() {
        #expect(EditorView.relativePath("/p/Sources/a.swift", project: "/p") == "Sources/a.swift")
        #expect(EditorView.relativePath("/p-evil/a.swift", project: "/p") == "/p-evil/a.swift")
        #expect(EditorView.relativePath("/p/a.swift", project: nil) == "/p/a.swift")
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gui-test-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func opened(_ file: URL, project: URL, rows: [WorkerRow] = [], drafts: EditorDrafts? = nil,
                        delay: Duration = .seconds(60),
                        writer: (@Sendable (String, URL, EditorAccess) -> EditorSave.Outcome)? = nil) async -> EditorStore {
        let drafts = drafts ?? EditorDrafts(folder: project.appendingPathComponent("drafts-outside"))
        let store = writer.map { EditorStore(writer: $0, drafts: drafts, draftDelay: delay) }
            ?? EditorStore(drafts: drafts, draftDelay: delay)
        store.configure(project: project, rows: rows)
        store.point(at: file)
        await settle(store)
        return store
    }

    private func settleSave(_ store: EditorStore, until done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func makeDrafts() -> EditorDrafts {
        EditorDrafts(folder: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gui-test-sdrafts-" + UUID().uuidString))
    }

    @Test func flushedDraftSurvivesAndRestoresExactly() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let drafts = makeDrafts(); defer { try? FileManager.default.removeItem(at: drafts.folder) }
        let file = root.appendingPathComponent("a.swift")
        try write("old\n", file)
        let first = await opened(file, project: root, drafts: drafts)
        first.edit("new\r\ntext \u{1F600}")
        first.flush()
        let second = await opened(file, project: root, drafts: drafts)
        #expect(second.pendingDraft == "new\r\ntext \u{1F600}")
        #expect(second.buffer == "old\n")
        #expect(try String(contentsOf: file, encoding: .utf8) == "old\n")
        second.restore()
        #expect(second.buffer == "new\r\ntext \u{1F600}")
        #expect(second.isDirty)
        #expect(second.pendingDraft == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "old\n")
    }

    @Test func discardRemovesTheDraftFile() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let drafts = makeDrafts(); defer { try? FileManager.default.removeItem(at: drafts.folder) }
        let file = root.appendingPathComponent("a.swift")
        try write("old", file)
        let first = await opened(file, project: root, drafts: drafts)
        first.edit("new")
        first.flush()
        let second = await opened(file, project: root, drafts: drafts)
        let draftFile = drafts.file(for: file.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(FileManager.default.fileExists(atPath: draftFile.path))
        second.discard()
        #expect(!FileManager.default.fileExists(atPath: draftFile.path))
        #expect(second.pendingDraft == nil)
    }

    @Test func terminateNotificationWritesAWaitingDraft() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let drafts = makeDrafts(); defer { try? FileManager.default.removeItem(at: drafts.folder) }
        let file = root.appendingPathComponent("a.swift")
        try write("old", file)
        let store = await opened(file, project: root, drafts: drafts, delay: .seconds(60))
        store.edit("new")
        let key = file.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(drafts.read(key) == nil)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(drafts.read(key) == "new")
    }

    @Test func quietPeriodWritesAndSaveRemovesTheDraft() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let drafts = makeDrafts(); defer { try? FileManager.default.removeItem(at: drafts.folder) }
        let file = root.appendingPathComponent("a.swift")
        try write("old", file)
        let store = await opened(file, project: root, drafts: drafts, delay: .milliseconds(20))
        let key = file.standardizedFileURL.resolvingSymlinksInPath().path
        store.edit("new")
        await settleSave(store) { drafts.read(key) != nil }
        #expect(drafts.read(key) == "new")
        store.save()
        await settleSave(store) { !store.isDirty }
        #expect(drafts.read(key) == nil)
    }

    @Test func readOnlyFileWritesNoDraftAndOffersNone() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let drafts = makeDrafts(); defer { try? FileManager.default.removeItem(at: drafts.folder) }
        let plan = root.appendingPathComponent(".planning/PLAN.md")
        try write("plan", plan)
        let key = plan.standardizedFileURL.resolvingSymlinksInPath().path
        try drafts.write("stale", for: key)
        let store = await opened(plan, project: root, drafts: drafts, delay: .milliseconds(10))
        store.edit("changed")
        store.flush()
        #expect(store.pendingDraft == nil)
        #expect(drafts.read(key) == "stale")
        let other = root.appendingPathComponent(".planning/B.md")
        try write("b", other)
        let second = await opened(other, project: root, drafts: drafts, delay: .milliseconds(10))
        second.edit("x")
        second.flush()
        #expect(drafts.read(other.standardizedFileURL.resolvingSymlinksInPath().path) == nil)
    }

    @Test func editedProjectFileSavesAndIsClean() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.swift")
        try write("old\n", file)
        let store = await opened(file, project: root)
        store.edit("new\r\n")
        #expect(store.isDirty)
        store.save()
        await settleSave(store) { !store.isDirty }
        #expect(!store.isDirty)
        #expect(try Data(contentsOf: file) == Data("new\r\n".utf8))
    }

    @Test func failedSaveKeepsTheBufferAndShowsTheReason() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.swift")
        try write("old", file)
        let store = await opened(file, project: root, writer: { _, _, _ in .failed("disk full") })
        store.edit("new")
        store.save()
        await settleSave(store) { store.saveFailure != nil }
        #expect(store.isDirty)
        #expect(store.saveFailure == "disk full")
        #expect(store.buffer == "new")
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
    }

    @Test func readOnlyFilesChangeNothing() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = root.appendingPathComponent(".planning/phases/4/PLAN.md")
        let tree = root.appendingPathComponent(".claude/worktrees/w1")
        let treeFile = tree.appendingPathComponent("a.swift")
        try write("plan", plan)
        try write("tree", treeFile)
        let rows = [WorkerRow(agentId: "w1", status: "running", taskTitle: nil, lastEvent: nil, worktreePath: tree.path)]
        func snapshot() throws -> [String: String] {
            var out: [String: String] = [:]
            for url in [plan, treeFile] {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                out[url.path] = try String(contentsOf: url, encoding: .utf8) + "\(attrs[.modificationDate] as? Date ?? .distantPast)"
            }
            return out
        }
        let before = try snapshot()
        for (file, baseline) in [(plan, "plan"), (treeFile, "tree")] {
            let store = await opened(file, project: root, rows: rows)
            #expect(!store.access.isEditable)
            store.edit("changed")
            store.save()
            try? await Task.sleep(for: .milliseconds(100))
            #expect(store.buffer == baseline)
            #expect(!store.isDirty)
        }
        #expect(try snapshot() == before)
    }

    private final class DiffCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return paths.count }
        var last: String? { lock.lock(); defer { lock.unlock() }; return paths.last }
        func record(_ url: URL) { lock.lock(); paths.append(url.path); lock.unlock() }
    }

    @Test func diffToggleReadsOnceSavesReadAgainAndLeavesTheBufferAlone() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let drafts = makeDrafts(); defer { try? FileManager.default.removeItem(at: drafts.folder) }
        let file = root.appendingPathComponent("a.swift")
        try write("old\n", file)
        let calls = DiffCalls()
        let blocks = [DiffBlock(path: nil, lines: [DiffLine(kind: .added, text: "x")])]
        let store = EditorStore(drafts: drafts, draftDelay: .seconds(60),
                                diffReader: { calls.record($0); return .blocks(blocks) })
        store.configure(project: root, rows: [])
        store.point(at: file)
        await settle(store)
        store.edit("edited\n")
        #expect(calls.count == 0 && store.diff == nil)
        store.toggleDiff()
        await settleSave(store) { store.diff != nil }
        #expect(calls.count == 1)
        #expect(calls.last == file.path)
        #expect(store.diff == .blocks(blocks))
        #expect(store.buffer == "edited\n" && store.isDirty)
        store.save()
        await settleSave(store) { calls.count == 2 }
        #expect(calls.count == 2)
        store.toggleDiff()
        #expect(store.diff == nil && !store.showsDiff)
        #expect(store.buffer == "edited\n")
        #expect(calls.count == 2)
    }

    @Test func outsideWriteReloadsACleanBufferAndFlagsADirtyOne() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let drafts = makeDrafts(); defer { try? FileManager.default.removeItem(at: drafts.folder) }
        let clean = root.appendingPathComponent("clean.swift"), dirty = root.appendingPathComponent("dirty.swift")
        try write("one\n", clean); try write("one\n", dirty)
        try await Task.sleep(for: .milliseconds(1500))
        let a = await opened(clean, project: root, drafts: drafts)
        let b = await opened(dirty, project: root, drafts: drafts)
        try await Task.sleep(for: .milliseconds(800))
        b.edit("mine\n")
        try write("two\n", clean); try write("two\n", dirty)
        await settleSave(a) { a.buffer == "two\n" }
        #expect(a.buffer == "two\n" && !a.isDirty && !a.changedOnDisk)
        await settleSave(b) { b.changedOnDisk }
        #expect(b.changedOnDisk && b.buffer == "mine\n")
        // Save does nothing while the flag is set.
        b.save()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try String(contentsOf: dirty, encoding: .utf8) == "two\n")
        b.reloadFromDisk()
        await settleSave(b) { !b.changedOnDisk }
        #expect(b.buffer == "two\n" && !b.isDirty && !b.changedOnDisk)
    }

    @Test func keepMineAllowsASaveAndTheOwnSaveRaisesNoFlag() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let drafts = makeDrafts(); defer { try? FileManager.default.removeItem(at: drafts.folder) }
        let file = root.appendingPathComponent("a.swift")
        try write("one\n", file)
        try await Task.sleep(for: .milliseconds(1500))
        let store = await opened(file, project: root, drafts: drafts)
        try await Task.sleep(for: .milliseconds(800))
        store.edit("mine\n")
        try write("two\n", file)
        await settleSave(store) { store.changedOnDisk }
        #expect(store.changedOnDisk)
        store.keepMine()
        #expect(!store.changedOnDisk && store.buffer == "mine\n")
        store.save()
        await settleSave(store) { !store.isDirty }
        #expect(try String(contentsOf: file, encoding: .utf8) == "mine\n")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!store.changedOnDisk && !store.isDirty && store.buffer == "mine\n")
    }
}
