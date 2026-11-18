import Foundation
import Testing
@testable import Helm

private final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

@MainActor @Suite(.serialized) struct UATScreenStoreTests {
    private static let uat = "---\nstatus: testing\nphase: 3\nfields_version: 1\n---\n\n## Items\n\n### 1. a\nexpected: e\nstatus: pending\n"
    private static let loaded = UATStatus.Outcome.loaded(UATStatus(
        status: "testing", counts: .init(pending: 1), result: "partial", firstPending: nil, ci: nil))

    private func project() throws -> String {
        let root = (NSTemporaryDirectory() + "uat-store-" + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(atPath: root + "/.claude/worktrees/w", withIntermediateDirectories: true)
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    }

    private func put(_ root: String, phase: String = "3", text: String = uat) throws {
        let dir = root + "/.planning/phases/\(phase)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try text.write(toFile: dir + "/UAT.md", atomically: true, encoding: .utf8)
    }

    private func loader(_ opened: Opened = Opened()) -> UATScreenLoader {
        UATScreenLoader(read: { opened.add($0); return try? String(contentsOfFile: $0, encoding: .utf8) },
                        status: { _, _ in Self.loaded })
    }

    @Test func noUatAnywhereIsNotStarted() throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let data = loader().load(project: p, phase: "3", worktree: p + "/.claude/worktrees/w")
        #expect(data.source == .none && data.status == .notStarted && data.file == nil)
    }

    @Test func worktreeCopyWinsThenProjectCopyAfterItIsGone() throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let wt = p + "/.claude/worktrees/w"
        try put(wt)
        #expect(loader().load(project: p, phase: "3", worktree: wt).source == .worktree)
        try FileManager.default.removeItem(atPath: wt)
        try put(p)
        #expect(loader().load(project: p, phase: "3", worktree: wt).source == .project)
    }

    @Test func aWorktreeOutsideTheWorktreesFolderIsIgnored() throws {
        let p = try project()
        let other = try project()
        defer { try? FileManager.default.removeItem(atPath: p); try? FileManager.default.removeItem(atPath: other) }
        try put(other)
        #expect(loader().load(project: p, phase: "3", worktree: other).source == .none)
    }

    @Test func onlyTheOneUatFileIsOpened() throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let wt = p + "/.claude/worktrees/w"
        try put(wt)
        try "secret".write(toFile: wt + "/.planning/phases/3/secret.txt", atomically: true, encoding: .utf8)
        let opened = Opened()
        _ = loader(opened).load(project: p, phase: "3", worktree: wt)
        #expect(opened.all == [wt + "/.planning/phases/3/UAT.md"])
    }

    @Test func aSymlinkedUatOutsideTheWorktreeIsNotRead() throws {
        let p = try project()
        let elsewhere = try project()
        defer { try? FileManager.default.removeItem(atPath: p); try? FileManager.default.removeItem(atPath: elsewhere) }
        try put(elsewhere)
        let wt = p + "/.claude/worktrees/w"
        try FileManager.default.createDirectory(atPath: wt + "/.planning/phases/3", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: wt + "/.planning/phases/3/UAT.md",
                                                   withDestinationPath: elsewhere + "/.planning/phases/3/UAT.md")
        let opened = Opened()
        let data = loader(opened).load(project: p, phase: "3", worktree: wt)
        #expect(data.source == .none && opened.all.isEmpty)
    }

    @Test func badPhaseTextBuildsNoPath() throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let opened = Opened()
        let data = loader(opened).load(project: p, phase: "../x", worktree: p + "/.claude/worktrees/w")
        #expect(data == UATScreenData() && opened.all.isEmpty)
        #expect(UATScreenLoader.watchFolder(project: p, phase: "../x", worktree: p + "/.claude/worktrees/w") == nil)
    }

    @Test func writingTheWorktreeUatRepublishesWithinFiveSeconds() async throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let wt = p + "/.claude/worktrees/w"
        try put(wt)
        let store = UATScreenStore(loader: loader())
        store.point(project: p, phase: "3", worktree: wt)
        for _ in 0..<300 where store.data.source != .worktree { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.data.source == .worktree)
        try await Task.sleep(for: .milliseconds(800))
        let before = store.data
        try put(wt, text: Self.uat.replacingOccurrences(of: "status: pending", with: "status: pass"))
        for _ in 0..<500 where store.data == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.data != before)
    }

    private final class Stub: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String] = []
        let gate: DispatchSemaphore?
        init(gate: DispatchSemaphore? = nil) { self.gate = gate }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return sent }
        func deliver(_ line: String, _ inbox: String) -> InboxDelivery.Outcome {
            lock.lock(); sent.append(line); lock.unlock()
            gate?.wait()
            return .sent
        }
    }

    private func sendStore(_ stub: Stub) -> UATScreenStore {
        UATScreenStore(loader: loader(), deliver: { stub.deliver($0, $1) })
    }

    private func settle(_ task: Task<Void, Never>?) async { await task?.value }

    @Test func passForTheCurrentItemDeliversExactlyOneLine() async {
        let stub = Stub()
        let store = sendStore(stub)
        await settle(store.send(item: "2", kind: .pass, text: nil, firstPending: 2, state: .running, live: true, inbox: "/i"))
        #expect(stub.lines == ["UAT item 2: pass"] && store.outcome == .sent)
    }

    @Test func otherItemsAndNonLiveWorkersDeliverNothingWithAReason() async {
        let stub = Stub()
        let store = sendStore(stub)
        await settle(store.send(item: "3", kind: .pass, text: nil, firstPending: 2, state: .running, live: true, inbox: "/i"))
        await settle(store.send(item: "2", kind: .pass, text: nil, firstPending: 2, state: .dead, live: false, inbox: "/i"))
        #expect(store.outcome == .refused("worker ended"))
        await settle(store.send(item: "2", kind: .pass, text: nil, firstPending: 2, state: .running, live: false, inbox: "/i"))
        #expect(store.outcome == .refused("starting"))
        await settle(store.send(item: "2", kind: .pass, text: nil, firstPending: 2, state: nil, live: false, inbox: "/i"))
        #expect(store.outcome == .refused("worker not running"))
        await settle(store.send(item: "2", kind: .pass, text: nil, firstPending: 2, state: .running, live: true, inbox: nil))
        #expect(store.outcome == .refused("worker has no inbox") && stub.lines.isEmpty)
    }

    @Test func aSecondSendWhileOneIsInFlightDoesNothing() async {
        let gate = DispatchSemaphore(value: 0)
        let stub = Stub(gate: gate)
        let store = sendStore(stub)
        let first = store.send(item: "2", kind: .pass, text: nil, firstPending: 2, state: .running, live: true, inbox: "/i")
        let second = store.send(item: "2", kind: .pass, text: nil, firstPending: 2, state: .running, live: true, inbox: "/i")
        #expect(second == nil)
        gate.signal()
        await settle(first)
        #expect(stub.lines.count == 1)
    }

    @Test func aShellSubstitutionInTheNoteCreatesNoFile() async {
        try? FileManager.default.removeItem(atPath: "/tmp/ac2")
        let stub = Stub()
        let store = sendStore(stub)
        await settle(store.send(item: "2", kind: .fail, text: "x\n$(touch /tmp/ac2)", firstPending: 2, state: .running, live: true, inbox: "/i"))
        #expect(stub.lines == ["UAT item 2: fail - x $(touch /tmp/ac2)"])
        #expect(!FileManager.default.fileExists(atPath: "/tmp/ac2"))
    }

    @Test func theRealAppendLeavesOneJsonLineWithTheContent() async throws {
        let inbox = NSTemporaryDirectory() + "uat-inbox-" + UUID().uuidString.prefix(8).lowercased()
        FileManager.default.createFile(atPath: inbox, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: inbox) }
        let store = UATScreenStore(loader: loader())
        await settle(store.send(item: "2", kind: .skip, text: "no device", firstPending: 2, state: .running, live: true, inbox: inbox))
        let lines = try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let json = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        let message = json?["message"] as? [String: Any]
        #expect(message?["content"] as? String == "UAT item 2: skip - no device")
    }

    @Test func theReadbackMovesFromWaitingToRecordedOnTheUatWatch() async throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let wt = p + "/.claude/worktrees/w"
        try put(wt)
        let store = sendStore(Stub())
        store.point(project: p, phase: "3", worktree: wt)
        for _ in 0..<300 where store.data.source != .worktree { try await Task.sleep(for: .milliseconds(10)) }
        await settle(store.send(item: "1", kind: .pass, text: nil, firstPending: 1, state: .running, live: true, inbox: "/i"))
        #expect(store.readback?.state == .waiting)
        try await Task.sleep(for: .milliseconds(800))
        try put(wt, text: Self.uat.replacingOccurrences(of: "status: pending", with: "status: pass"))
        for _ in 0..<500 where store.readback?.state == .waiting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.readback?.state == .recorded(status: "pass", note: nil))
    }

    @Test func loadingChangesNothingUnderPlanning() throws {
        let p = try project()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let wt = p + "/.claude/worktrees/w"
        try put(wt)
        try put(p)
        func stamps() -> [String: Date] {
            var out: [String: Date] = [:]
            for root in [p, wt] {
                for f in (FileManager.default.enumerator(atPath: root + "/.planning")?.allObjects as? [String]) ?? [] {
                    out[root + f] = (try? FileManager.default.attributesOfItem(atPath: root + "/.planning/" + f))?[.modificationDate] as? Date
                }
            }
            return out
        }
        let before = stamps()
        _ = UATScreenLoader().load(project: p, phase: "3", worktree: wt)
        #expect(stamps() == before)
        #expect(!before.keys.contains { $0.hasSuffix("trace.jsonl") } && !stamps().keys.contains { $0.hasSuffix("trace.jsonl") })
    }
}
