import Foundation
import Testing
@testable import OrchestratorGUI

/// AC7: a refresh, a press and an override change nothing under `.planning/` and no Cadence config.
@MainActor @Suite struct WorkflowReadOnlyTests {
    nonisolated static var cadenceFound: Bool {
        if case .success = CadenceLocator.locate() { return true }
        return false
    }

    private func sh(_ args: [String], in dir: String) -> String {
        let result = ProcessRunner.run("/usr/bin/git", args, environment: ["HOME": NSHomeDirectory()], workingFolder: dir, timeout: 20)
        return result.stdout
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    @Test(.enabled(if: WorkflowReadOnlyTests.cadenceFound, "node or the Cadence install is missing"))
    func refreshPressAndOverrideWriteNothing() async throws {
        let repo = NSTemporaryDirectory() + "WorkflowReadOnly-\(UUID().uuidString)"
        let planning = repo + "/.planning"
        let fm = FileManager.default
        try fm.createDirectory(atPath: planning + "/phases/1", withIntermediateDirectories: true)
        try "# Roadmap\n\n## Phases\n\n- [ ] **Phase 1: Alpha** - fixture\n".write(toFile: planning + "/ROADMAP.md", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: planning + "/records", withIntermediateDirectories: true)
        try ("{\"layout\":1,\"cycleOpen\":true,\"cursor\":null,\"phases\":["
             + "{\"n\":1,\"name\":\"Alpha\",\"description\":\"fixture\",\"status\":\"unplanned\",\"plans\":[]}],\"requirements\":[]}\n")
            .write(toFile: planning + "/records/state.json", atomically: true, encoding: .utf8)
        try "/trace.jsonl\n".write(toFile: planning + "/records/.gitignore", atomically: true, encoding: .utf8)
        try "{}\n".write(toFile: planning + "/config.json", atomically: true, encoding: .utf8)
        _ = sh(["init", "-q"], in: repo)
        _ = sh(["add", "-A"], in: repo)
        _ = sh(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fixture"], in: repo)
        defer { try? fm.removeItem(atPath: repo) }

        let userConfig = NSHomeDirectory() + "/.claude/cadence/config.json"
        let before = (modified(planning + "/config.json"), modified(userConfig))

        let sent = SentLines()
        let store = WorkflowStore(liveness: { _ in nil }, routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                  makeDeliver: { _ in { sent.add($0); return .sent } })
        store.point(at: repo, base: "base")
        for _ in 0..<1500 where store.board == nil && store.failure == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.board != nil, "refresh failed: \(store.failure ?? "no result")")
        await store.press()
        _ = await store.sendOverride(reason: "because")

        #expect(sh(["status", "--porcelain", ".planning"], in: repo).isEmpty)
        #expect(modified(planning + "/config.json") == before.0)
        #expect(modified(userConfig) == before.1)
    }
}

private final class SentLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
}
