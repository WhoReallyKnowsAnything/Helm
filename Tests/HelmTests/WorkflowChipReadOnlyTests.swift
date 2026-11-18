import Foundation
import Testing
@testable import Helm

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return _all }
    func add(_ line: String) { lock.lock(); _all.append(line); lock.unlock() }
}

/// Runs the real refresh path against the live Cadence install and node. Skipped, with the reason shown, when either is missing.
@MainActor
@Suite(.enabled(if: { if case .success = CadenceLocator.locate() { return true } else { return false } }(),
                "node or the Cadence install is missing"))
struct WorkflowChipReadOnlyTests {
    private let env = ["PATH": "/usr/bin:/bin"]

    private func fixture() throws -> String {
        let root = NSTemporaryDirectory() + "chips-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/.planning/phases/1", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.planning/phases/2", withIntermediateDirectories: true)
        try "# Roadmap\n\n## Phases\n\n- [ ] **Phase 1: First** - a\n- [ ] **Phase 2: Second** - b\n"
            .write(toFile: root + "/.planning/ROADMAP.md", atomically: true, encoding: .utf8)
        try "# Context\n\n- D-01: keep it.\n".write(toFile: root + "/.planning/phases/2/CONTEXT.md", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: root + "/.planning/records", withIntermediateDirectories: true)
        try ("{\"layout\":1,\"cycleOpen\":true,\"cursor\":null,\"phases\":["
             + "{\"n\":1,\"name\":\"First\",\"description\":\"a\",\"status\":\"unplanned\",\"plans\":[]},"
             + "{\"n\":2,\"name\":\"Second\",\"description\":\"b\",\"status\":\"planned\",\"plans\":[]}],\"requirements\":[]}\n")
            .write(toFile: root + "/.planning/records/state.json", atomically: true, encoding: .utf8)
        try "/trace.jsonl\n".write(toFile: root + "/.planning/records/.gitignore", atomically: true, encoding: .utf8)
        try "{\"a\":1}\n".write(toFile: root + "/.planning/records/trace.jsonl", atomically: true, encoding: .utf8)
        try "{}\n".write(toFile: root + "/.planning/config.json", atomically: true, encoding: .utf8)
        #expect(ProcessRunner.run("/usr/bin/git", ["init", "-q"], environment: env, workingFolder: root, timeout: 20).status == 0)
        return root
    }

    private func porcelain(_ root: String, _ path: String? = nil) -> String {
        ProcessRunner.run("/usr/bin/git", ["status", "--porcelain"] + (path.map { [$0] } ?? []),
                          environment: env, workingFolder: root, timeout: 20).stdout
    }

    private func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    @Test func refreshesChipsAndConfigFixWriteNothingAndSendOnlyBoardLines() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let trace = root + "/.planning/records/trace.jsonl"
        let global = NSHomeDirectory() + "/.claude/cadence/config.json"
        let before = (FileManager.default.contents(atPath: trace), porcelain(root), mtime(root + "/.planning/config.json"), mtime(global))

        // Case A: ten real refreshes (status, health, config check and the suggest read).
        for _ in 0..<10 { _ = try WorkflowStore.liveSource(root).get() }
        #expect(FileManager.default.contents(atPath: trace) == before.0)
        #expect(porcelain(root) == before.1)

        // Case B: a press of every chip type, a config fix and a fix-all, with a stub delivery.
        let lines = Lines()
        let store = WorkflowStore(
            source: { _ in .success(WorkflowBoard(milestone: "m", rows: [])) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: "chips.\(UUID().uuidString)")!),
            makeDeliver: { _ in { lines.add($0); return .sent } },
            labels: { _ in .success([]) })
        store.point(at: root, base: "base")
        for _ in 0..<300 where store.panel == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let chips: [CadenceChip] = [
            .init(skill: "/cadence:cad-audit", phase: nil, rule: "r"),
            .init(skill: "/cadence:cad-health", phase: nil, rule: "r"),
            .init(skill: "/cadence:cad-suggest", phase: nil, rule: "r"),
            .init(skill: "/cadence:cad-coverage", phase: "1", rule: "r"),
            .init(skill: "/cadence:cad-minimalism-review", phase: "1", rule: "r"),
            .init(skill: "/cadence:cad-decision-review", phase: "2", argument: "D-01", rule: "r"),
        ]
        let rows = CadenceConfigCheck.recommended.map {
            CadenceConfigCheck.Row(key: $0.key, current: nil, recommended: $0.value, differs: true)
        }
        let check = CadenceConfigCheck(rows: rows, warnings: [], reviewerModel: "sonnet", reviewerEffort: "medium")
        let fixes = [check.fixChip(key: rows[0].key), check.fixAllChip()].compactMap { $0 }
        for chip in chips + fixes { await store.pressChip(chip) }
        #expect(!lines.all.isEmpty)
        #expect(porcelain(root, ".planning").isEmpty || porcelain(root, ".planning") == before.1)
        #expect(mtime(root + "/.planning/config.json") == before.2)
        #expect(mtime(global) == before.3)

        // Case C: every line is a single board line without --global.
        for line in lines.all {
            #expect(line.hasPrefix("Cadence stage: skill="))
            #expect(!line.contains("\n") && !line.contains("\r"))
            #expect(!line.contains("--global"))
        }
    }
}
