import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct ExecuteCadenceTests {
    private let replay = """
    {"ok":true,"phase":1,"plan_count":2,"reports":[
    {"plan":"PLAN-1.md","k":1,"report":"phases/1/records/reports/plan-1.md","exists":true,"status":"PLAN PARTIAL","complete":false,"name":"First"},
    {"plan":"PLAN-2.md","k":2,"report":"phases/1/records/reports/plan-2.md","exists":false,"status":null,"complete":false}]}
    """

    @Test func parsesAPartialAndAMissingReport() {
        guard case .loaded(let plans, _) = ExecuteCadence.parseReplay(replay) else { Issue.record("not loaded"); return }
        #expect(plans.count == 2)
        #expect(plans[0].status == "PLAN PARTIAL" && plans[0].exists && plans[0].name == "First")
        #expect(plans[1].status == nil && !plans[1].exists && plans[1].name == nil && plans[1].k == 2)
    }

    @Test func parsesWavesExactlyAsGiven() {
        let text = #"{"ok":true,"phase":1,"plans":[],"waves":[["PLAN-1.md"],["PLAN-2.md"]]}"#
        #expect((try? ExecuteCadence.parseWaves(text).get()) == [["PLAN-1.md"], ["PLAN-2.md"]])
    }

    @Test func noPhaseDirIsItsOwnCase() {
        let text = #"{"ok":false,"reason":"no-phase-dir","detail":".planning/phases/99 not found"}"#
        #expect(ExecuteCadence.parseReplay(text) == .noPhaseDir)
        guard case .failure(let outcome) = ExecuteCadence.parseWaves(text) else { Issue.record("not failed"); return }
        #expect(outcome == .noPhaseDir)
    }

    @Test func garbageIsUnreadable() {
        guard case .unreadable = ExecuteCadence.parseReplay("not json") else { Issue.record("not unreadable"); return }
        guard case .unreadable = ExecuteCadence.parseReplay(#"{"ok":true}"#) else { Issue.record("not unreadable"); return }
        guard case .failure(.unreadable) = ExecuteCadence.parseWaves(#"{"ok":true}"#) else { Issue.record("not unreadable"); return }
    }

    @Test func anInvalidPhaseNeverStartsAProcess() {
        let scripts = CadenceLocator.Scripts(node: "/nonexistent/node", planning: "/x", config: "/x")
        #expect(ExecuteCadence.run(scripts, root: "/tmp", phase: "1; rm -rf /")
                == .unreadable("Phase text is not a plain number."))
        #expect(ExecuteCadence.run(scripts, root: "/tmp", phase: "../1")
                == .unreadable("Phase text is not a plain number."))
    }

    @Test func realScriptsAgreeWithTheParser() throws {
        guard case .success(let scripts) = CadenceLocator.locate() else { return }
        let dir = NSTemporaryDirectory() + UUID().uuidString
        let phase = "\(dir)/.planning/phases/1"
        try FileManager.default.createDirectory(atPath: "\(phase)/records/reports", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for k in 1...2 {
            let text = "---\nphase: 1\nplan: \(k)\nfiles:\n  - shared.swift\n---\n\n# Phase 1: x - Plan \(k): P\(k)\n"
            try text.write(toFile: "\(phase)/PLAN-\(k).md", atomically: true, encoding: .utf8)
        }
        // 4.3.0 replay-check answers no-roadmap without a ROADMAP.md.
        try "# Roadmap\n\n## Phases\n\n- [ ] **Phase 1: x** - y\n".write(toFile: "\(dir)/.planning/ROADMAP.md", atomically: true, encoding: .utf8)
        try "PLAN PARTIAL\nPlan: x\n".write(toFile: "\(phase)/records/reports/plan-1.md", atomically: true, encoding: .utf8)
        let outcome = ExecuteCadence.run(scripts, root: dir, phase: "1")
        guard case .loaded(let plans, let waves) = outcome else {
            Issue.record("not loaded: \(outcome)"); return
        }
        #expect(plans.map(\.status) == ["PLAN PARTIAL", nil])
        #expect(plans.map(\.exists) == [true, false])
        #expect(waves == [["PLAN-1.md"], ["PLAN-2.md"]])
        #expect(ExecuteCadence.run(scripts, root: dir, phase: "99") == .noPhaseDir)
    }
}
