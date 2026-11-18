import Foundation
import Testing
@testable import Helm

private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return all }
    func add(_ line: String, to inbox: String) {
        lock.lock(); all.append(line); lock.unlock()
        if let handle = FileHandle(forWritingAtPath: inbox) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }
}

@MainActor @Suite(.serialized) struct MilestoneReadOnlyTests {
    private func modTimes(_ dir: String) -> [String: Date] {
        var result: [String: Date] = [:]
        for case let path as String in FileManager.default.enumerator(atPath: dir) ?? FileManager.default.enumerator(atPath: "/")! {
            result[path] = (try? FileManager.default.attributesOfItem(atPath: dir + "/" + path))?[.modificationDate] as? Date
        }
        return result
    }

    private func git(_ args: [String], in dir: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func loadersCloseOverrideAndLandWriteNothingUnderPlanning() async throws {
        let raw = NSTemporaryDirectory() + "milestone-ro-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: raw + "/.planning", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: raw) }
        let root = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        try "Milestone v4: x\n".write(toFile: root + "/.planning/ROADMAP.md", atomically: true, encoding: .utf8)
        try "## Notes\n- ship $(touch /tmp/ac6m3) now\n".write(toFile: root + "/.planning/CAPTURE.md", atomically: true, encoding: .utf8)
        _ = try git(["init", "-q", "-b", "main"], in: root)
        _ = try git(["add", ".planning"], in: root)
        _ = try git(["commit", "-q", "-m", "init"], in: root)
        let worktree = root + "/.claude/worktrees/cad-milestone-p1"
        try FileManager.default.createDirectory(atPath: root + "/.claude/worktrees", withIntermediateDirectories: true)
        _ = try git(["worktree", "add", "-q", "-b", "session/cad-milestone-p1", worktree], in: root)
        let inbox = root + "/inbox.jsonl"
        FileManager.default.createFile(atPath: inbox, contents: nil)
        try? FileManager.default.removeItem(atPath: "/tmp/ac6m3")

        let before = modTimes(root + "/.planning")
        let sent = Sent()
        let st = CadenceStatus(current: "1", total: 1, cycle: nil, phases: [.init(n: "1", name: "a", status: "planned")], cursorNext: nil)
        let roles = Dictionary(uniqueKeysWithValues: CadenceConfig.agents.map { ($0, CadenceConfig.Role(model: "sonnet", effort: "medium")) })
        let cfg = CadenceConfig(skipDiscuss: false, planCheck: true, roles: roles)
        let audit: Result<Int, CadenceLocator.Failure> = .success(0)
        let (next, ahead) = WorkflowBoard.derive(status: st, config: cfg, hasContext: true, audit: audit)
        let board = WorkflowBoard(milestone: "m", rows: [], status: st, config: cfg, audit: audit, next: next, skipAhead: ahead)
        let store = WorkflowStore(
            source: { _ in .success(board) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeDeliver: { _ in { sent.add($0, to: inbox); return .sent } },
            labels: { _ in .success(["cad-milestone-p1"]) })
        store.point(at: root, base: "base")
        for _ in 0..<300 where store.milestoneTarget == nil { try? await Task.sleep(for: .milliseconds(10)) }

        // Plan 1 and Plan 2 loaders.
        _ = MilestoneLandFacts.read(project: root, worktree: worktree)
        _ = MilestoneLandTags.local(version: MilestoneLandTags.version(project: root, worktree: worktree), project: root)
        _ = MilestoneClosed(status: { _ in .success(st) }).read(project: root, worktree: worktree)
        let captured = MilestoneCapture.read(project: root, worktree: worktree, reason: "ship $(touch /tmp/ac6m3) now")
        #expect(captured == ["- ship $(touch /tmp/ac6m3) now"])
        let screen = MilestoneScreenStore(run: { _ in .failure(.init(reason: "x")) },
                                          land: MilestoneLandReader(
                                              facts: { _, _ in .noWorktree }, version: { _, _ in "4" },
                                              localTag: { _, _ in .absent }, originTag: { _, _ in .absent },
                                              closed: { _, _ in .open }),
                                          find: { _, _, _ in .noPullRequest })
        screen.point(project: root, worktree: worktree, label: "cad-milestone-p1")
        await screen.reload(origin: true)?.value

        // Close, override and land, with the reason holding a command substitution.
        #expect(await store.closeMilestone())
        store.setRows([WorkerRow(agentId: "cad-milestone-p1", status: "running", taskTitle: nil, lastEvent: nil,
                                 createdAt: "2026-11-11 08:00:00")])
        // The held worker refuses a second close; landing needs the live row.
        for _ in 0..<300 where store.milestoneState == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await store.landMilestone())
        #expect(sent.lines.count == 2)
        #expect(sent.lines[1].hasPrefix("Cadence stage: skill=/cadence:cad-land"))
        let text = try String(contentsOfFile: inbox, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)

        let overrideStore = WorkflowStore(
            source: { _ in .success(board) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeDeliver: { _ in { sent.add($0, to: inbox); return .sent } },
            labels: { _ in .success([]) })
        overrideStore.point(at: root, base: "base")
        for _ in 0..<300 where overrideStore.milestoneTarget == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await overrideStore.overrideMilestone(reason: "x $(touch /tmp/ac6m3)"))
        #expect(sent.lines.count == 3)
        #expect(sent.lines[2].hasSuffix("x $(touch /tmp/ac6m3)"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/ac6m3"))
        #expect(try git(["status", "--porcelain", ".planning"], in: root).isEmpty)
        #expect(modTimes(root + "/.planning") == before)
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Helm/" + name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func noMilestoneSourceWritesAFile() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Helm")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("Milestone") && $0.hasSuffix(".swift") }
        #expect(names.count >= 8)
        for name in names {
            let text = try source(name)
            for pattern in [#"\.write\("#, "createFile", "UserDefaults", "AppStorage"] {
                #expect(text.range(of: pattern, options: .regularExpression) == nil, "\(name) matches \(pattern)")
            }
        }
    }
}
