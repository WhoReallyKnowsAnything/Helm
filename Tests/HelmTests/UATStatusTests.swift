import Foundation
import Testing
@testable import Helm

@Suite struct UATStatusTests {
    private let complete = #"{"ok":true,"status":"testing","counts":{"pass":6,"fail":0,"pending":0,"skipped":0,"blocked":0},"result":"complete"}"#
    private let partial = #"{"ok":true,"status":"testing","counts":{"pass":0,"fail":0,"pending":6,"skipped":0,"blocked":0},"result":"partial","#
        + #""first_pending":{"k":1,"name":"Board C","expected":"Rows show a label."}}"#

    @Test func completePayloadGivesCountsAndResult() {
        guard case .loaded(let s) = UATStatus.parse(complete) else { Issue.record("not loaded"); return }
        #expect(s.counts.pass == 6 && s.counts.pending == 0 && s.result == "complete" && s.firstPending == nil)
    }

    @Test func partialPayloadGivesFirstPending() {
        guard case .loaded(let s) = UATStatus.parse(partial) else { Issue.record("not loaded"); return }
        #expect(s.result == "partial" && s.counts.pending == 6)
        #expect(s.firstPending == .init(k: 1, name: "Board C", expected: "Rows show a label."))
    }

    @Test func noUatIsNotStarted() {
        #expect(UATStatus.parse(#"{"ok":false,"reason":"no-uat","detail":"x"}"#) == .notStarted)
    }

    @Test func otherFailuresAndBadResultAreUnreadable() {
        for text in ["garbage", "", #"{"ok":false,"reason":"bad-args"}"#,
                     #"{"ok":true,"counts":{},"result":"done"}"#] {
            guard case .unreadable(let why) = UATStatus.parse(text) else { Issue.record("loaded: \(text)"); continue }
            #expect(!why.isEmpty)
        }
    }

    @Test func phaseTextOutsideTheShapeRunsNothing() {
        let scripts = CadenceLocator.Scripts(node: "/nonexistent", planning: "/nonexistent", config: "/nonexistent")
        for phase in ["../x", "3x", "", "3.", "1;ls"] {
            #expect(UATStatus.run(scripts, folder: "/tmp", phase: phase) == .unreadable("Phase text is not a plain number."))
        }
        #expect(UATStatus.isValidPhase("3") && UATStatus.isValidPhase("1.1"))
    }

    private func script(_ body: String) throws -> CadenceLocator.Scripts {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("s.sh").path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return CadenceLocator.Scripts(node: "/bin/sh", planning: path, config: path)
    }

    @Test func exitOneGarbageAndTimeoutAreUnreadable() throws {
        guard case .unreadable = UATStatus.run(try script("echo boom >&2; exit 1"), folder: "/tmp", phase: "3") else {
            Issue.record("exit 1 loaded"); return
        }
        guard case .unreadable = UATStatus.run(try script("echo nope"), folder: "/tmp", phase: "3") else {
            Issue.record("garbage loaded"); return
        }
        guard case .unreadable(let why) = UATStatus.run(try script("sleep 5"), folder: "/tmp", phase: "3", timeout: 0.3) else {
            Issue.record("timeout loaded"); return
        }
        #expect(why.contains("timed out"))
    }

    @Test func aSuccessPayloadWithANonZeroExitIsNotLoaded() throws {
        let scripts = try script("echo '\(complete)'; exit 2")
        guard case .unreadable = UATStatus.run(scripts, folder: "/tmp", phase: "3") else { Issue.record("loaded"); return }
    }

    @Test func realCommandCountsTheLiteralAndWritesNoTrace() throws {
        guard case .success(let scripts) = CadenceLocator.locate() else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent(".planning/phases/3")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# Roadmap\n\n## Phases\n\n- [ ] **Phase 3: Third** - c\n"
            .write(to: root.appendingPathComponent(".planning/ROADMAP.md"), atomically: true, encoding: .utf8)
        let items = (1...3).map { "### \($0). item \($0)\nexpected: e\($0)\nstatus: \($0 == 3 ? "pending" : "pass")\n" }
            .joined(separator: "\n")
        try ("---\nstatus: testing\nphase: 3\nfields_version: 1\nstarted: 2026-11-10\nupdated: 2026-11-10\n---\n\n## Items\n\n" + items)
            .write(to: dir.appendingPathComponent("UAT.md"), atomically: true, encoding: .utf8)
        guard case .loaded(let s) = UATStatus.run(scripts, folder: root.path, phase: "3") else { Issue.record("not loaded"); return }
        #expect(s.counts.pass == 2 && s.counts.pending == 1 && s.result == "partial" && s.firstPending?.k == 3)
        let found = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
        #expect(!found.contains { $0.hasSuffix("trace.jsonl") })
        guard case .notStarted = UATStatus.run(scripts, folder: root.path, phase: "9") else { Issue.record("phase 9 loaded"); return }
    }
}
