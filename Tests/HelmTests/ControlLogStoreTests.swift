import Foundation
import Testing
@testable import Helm

@MainActor
struct ControlLogStoreTests {
    private let request = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"a":1},"tool_use_id":"t1"}}"#
    private let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#

    private func folder() throws -> String {
        let path = NSTemporaryDirectory() + "gui-test-ctl-" + UUID().uuidString.prefix(8).lowercased()
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

    @Test func aRequestWrittenAfterCreationIsPublishedAndItsToolResultRemovesIt() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/a.out.jsonl"
        try append("", to: out)
        let store = ControlLogStore(path: out)
        try append(request + "\n", to: out)
        try await wait { store.pending.count == 1 }
        #expect(store.pending.map(\.requestId) == ["r1"])

        let restarted = ControlLogStore(path: out)
        try await wait { restarted.pending.count == 1 }
        #expect(restarted.pending.map(\.requestId) == ["r1"])

        try append(toolResult + "\n", to: out)
        try await wait { store.pending.isEmpty }
        #expect(store.pending.isEmpty)
    }

    @Test func anInboxWriteInTheSameFolderChangesNothing() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/a.out.jsonl", inbox = dir + "/a.in.jsonl"
        try append(request + "\n", to: out)
        let store = ControlLogStore(path: out)
        try await wait { store.pending.count == 1 }
        try append(#"{"type":"user","message":{"content":"hi"}}"# + "\n", to: inbox)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(store.pending.map(\.requestId) == ["r1"])
    }

    @Test func aShorterReplacementFileResetsTheFold() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/a.out.jsonl"
        try append(request + "\n", to: out)
        let store = ControlLogStore(path: out)
        try await wait { store.pending.count == 1 }
        try "{}\n".write(toFile: out, atomically: true, encoding: .utf8)
        try await wait { store.pending.isEmpty }
        #expect(store.pending.isEmpty)
    }

    @Test func aMissingFolderPublishesNothing() {
        let store = ControlLogStore(path: NSTemporaryDirectory() + "no-such-\(UUID().uuidString)/a.out.jsonl")
        #expect(store.pending.isEmpty)
    }

    @Test func theModelAndInterruptStateFollowTheSameLineStream() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/a.out.jsonl"
        try append("", to: out)
        let store = ControlLogStore(path: out)
        store.noteInterrupt(id: "req-int-1")
        #expect(store.control.interrupt == .sending)
        let text = try ConversationFixtures.lines("interrupt-tool").joined(separator: "\n") + "\n"
        try append(text, to: out)
        try await wait { store.control.interrupt == .ended }
        #expect(store.control.interrupt == .ended)
        #expect(store.control.model == "claude-haiku-5-5")
    }
}
