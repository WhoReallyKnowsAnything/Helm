import Foundation
import Testing
@testable import OrchestratorGUI

/// Runs the real refresh path against the live Cadence install and node. Skipped, with the reason shown, when either is missing.
@Suite(.enabled(if: { if case .success = CadenceLocator.locate() { return true } else { return false } }(),
                "node or the Cadence install is missing"))
struct WorkflowHealthReadOnlyTests {
    private func fixture() throws -> String {
        let root = NSTemporaryDirectory() + "health-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/.planning/phases/1", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.planning/debug", withIntermediateDirectories: true)
        // Phase 2 has a checked box and no work on disk: one roadmap-box drift entry.
        try "# Roadmap\n\n## Phases\n\n- [ ] **Phase 1: First** - a\n- [x] **Phase 2: Second** - b\n"
            .write(toFile: root + "/.planning/ROADMAP.md", atomically: true, encoding: .utf8)
        try "Status: open\n".write(toFile: root + "/.planning/debug/a.md", atomically: true, encoding: .utf8)
        try "Status: resolved\n".write(toFile: root + "/.planning/debug/b.md", atomically: true, encoding: .utf8)
        try "# Capture\n\n## Todos\n\n- one\n- two\n".write(toFile: root + "/.planning/CAPTURE.md", atomically: true, encoding: .utf8)
        // 4.3 keeps phase state and the trace under records/. State says phase 2 is complete, the disk derives unplanned: one drift entry.
        try fm.createDirectory(atPath: root + "/.planning/records", withIntermediateDirectories: true)
        try ("{\"layout\":1,\"cycleOpen\":true,\"cursor\":null,\"phases\":["
             + "{\"n\":1,\"name\":\"First\",\"description\":\"a\",\"status\":\"unplanned\",\"plans\":[]},"
             + "{\"n\":2,\"name\":\"Second\",\"description\":\"b\",\"status\":\"complete\",\"plans\":[]}],\"requirements\":[]}\n")
            .write(toFile: root + "/.planning/records/state.json", atomically: true, encoding: .utf8)
        try "/trace.jsonl\n".write(toFile: root + "/.planning/records/.gitignore", atomically: true, encoding: .utf8)
        try "{\"a\":1}\n".write(toFile: root + "/.planning/records/trace.jsonl", atomically: true, encoding: .utf8)
        let git = ProcessRunner.run("/usr/bin/git", ["init", "-q"], environment: ["PATH": "/usr/bin:/bin"], workingFolder: root, timeout: 20)
        #expect(git.status == 0)
        return root
    }

    private func direct(_ scripts: CadenceLocator.Scripts, _ root: String, _ command: String) throws -> [String: Any] {
        let run = ProcessRunner.run(
            scripts.node, [scripts.planning, command],
            environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()], workingFolder: root, timeout: 20)
        return try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
    }

    private func board(_ root: String) throws -> WorkflowBoard {
        try WorkflowStore.liveSource(root).get()
    }

    @Test func stripEqualsItsSourcesRunDirectly() throws {
        guard case .success(let scripts) = CadenceLocator.locate() else { return }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let health = try #require(try board(root).health)

        let status = try direct(scripts, root, "status")
        let drift = (status["drift"] as? [Any])?.count ?? 0
        let outstanding = (status["outstanding"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["plans"] as? [Any])?.count ?? 0) }
        #expect(drift >= 1)
        #expect(health.drift == .success(drift))
        #expect(health.outstanding == .success(outstanding))
        #expect(health.audit == CadenceConfig.runAudit(scripts, project: root))
        #expect(health.debug == .success(1))
        let capture = try direct(scripts, root, "capture-sections")
        let todos = (capture["sections"] as? [[String: Any]])?.first { $0["heading"] as? String == "Todos" }?["bullets"] as? Int
        #expect(todos == 2)
        #expect(health.capture == .success(2))
    }

    @Test func tenRefreshesChangeNothing() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        let global = NSHomeDirectory() + "/.claude/cadence/config.json"
        func mtime(_ path: String) -> Date? { (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
        func porcelain() -> String {
            ProcessRunner.run("/usr/bin/git", ["status", "--porcelain"], environment: ["PATH": "/usr/bin:/bin"], workingFolder: root, timeout: 20).stdout
        }
        let trace = root + "/.planning/records/trace.jsonl"
        let before = (fm.contents(atPath: trace), porcelain(), mtime(root + "/.planning/config.json"), mtime(global))
        for _ in 0..<10 { _ = try board(root) }
        #expect(fm.contents(atPath: trace) == before.0)
        #expect(porcelain() == before.1)
        #expect(mtime(root + "/.planning/config.json") == before.2)
        #expect(mtime(global) == before.3)
    }
}
