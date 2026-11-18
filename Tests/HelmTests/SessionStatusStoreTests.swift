import Foundation
import Testing
@testable import Helm

@MainActor
struct SessionStatusStoreTests {
    private let user = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
    private let result = #"{"type":"result","subtype":"success","queued_turn_count":0}"#

    private func folder() throws -> String {
        let path = NSTemporaryDirectory() + "gui-test-sst-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func append(_ text: String, to path: String) throws {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func appendedLinesFlipTheTurnStateAndThePublishedTimeIsTheFileTime() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/a.out.jsonl"
        try append("", to: out)
        let store = SessionStatusStore()
        store.follow([out])
        try append(user + "\n", to: out)
        try await wait { store.entries[out]?.fold.turnInProgress == true }
        #expect(store.entries[out]?.fold.turnInProgress == true)
        try append(result + "\n", to: out)
        try await wait { store.entries[out]?.fold.turnInProgress == false }
        #expect(store.entries[out]?.fold.turnInProgress == false)
        let modified = try FileManager.default.attributesOfItem(atPath: out)[.modificationDate] as? Date
        #expect(store.entries[out]?.modified == modified)
    }

    @Test func aSiblingInboxWriteChangesNothing() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/a.out.jsonl", inbox = dir + "/a.in.jsonl"
        try append(user + "\n", to: out)
        let store = SessionStatusStore()
        store.follow([out])
        try await wait { store.entries[out] != nil }
        let before = store.entries[out]
        try append(user + "\n", to: inbox)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(store.entries[out] == before)
    }

    @Test func aMissingPathHasNoEntryAndGetsOneWhenTheFileAppears() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/late.out.jsonl"
        let store = SessionStatusStore()
        store.follow([out])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(store.entries[out] == nil)
        try append(user + "\n", to: out)
        try await wait { store.entries[out] != nil }
        #expect(store.entries[out]?.fold.turnInProgress == true)
    }

    @Test func aMissingFolderIsFollowedWithoutAWatcherOrAnEntry() {
        let store = SessionStatusStore()
        store.follow([NSTemporaryDirectory() + "gui-test-sst-nope-" + UUID().uuidString + "/x.jsonl"])
        #expect(store.entries.isEmpty)
    }

    @Test func sameFileNameInTwoFoldersStaysSeparate() async throws {
        let one = try folder(), two = try folder()
        defer { try? FileManager.default.removeItem(atPath: one); try? FileManager.default.removeItem(atPath: two) }
        let a = one + "/out.jsonl", b = two + "/out.jsonl"
        try append(user + "\n", to: a)
        try append(user + "\n" + result + "\n", to: b)
        let store = SessionStatusStore()
        store.follow([a, b])
        try await wait { store.entries[a] != nil && store.entries[b] != nil }
        #expect(store.entries[a]?.fold.turnInProgress == true)
        #expect(store.entries[b]?.fold.turnInProgress == false)
    }

    @Test func replacingTheFileWithAShorterOneResetsTheFold() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/a.out.jsonl"
        try append(user + "\n" + user + "\n" + result + "\n", to: out)
        let store = SessionStatusStore()
        store.follow([out])
        try await wait { store.entries[out]?.fold.turnInProgress == false }
        try Data((user + "\n").utf8).write(to: URL(fileURLWithPath: out))
        try await wait { store.entries[out]?.fold.turnInProgress == true }
        #expect(store.entries[out]?.fold.turnInProgress == true)
    }

    @Test func unfollowingAPathRemovesItsEntry() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/a.out.jsonl"
        try append(user + "\n", to: out)
        let store = SessionStatusStore()
        store.follow([out])
        try await wait { store.entries[out] != nil }
        store.follow([])
        #expect(store.entries[out] == nil)
    }

    /// A worker's folder is created after its row is stamped. The next `follow` of the same set must pick the log up.
    @Test func aFolderThatAppearsAfterTheFirstFollowIsPickedUpByTheNextFollow() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sub = dir + "/later"
        let out = sub + "/out.jsonl"
        let store = SessionStatusStore()
        store.follow([out])
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try append(user + "\n", to: out)
        store.follow([out])
        try await wait { store.entries[out] != nil }
        #expect(store.entries[out]?.fold.turnInProgress == true)
    }
}
