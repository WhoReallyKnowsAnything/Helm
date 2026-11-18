import Foundation
import Testing
@testable import Helm

private final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ p: String) { lock.lock(); list.append(p); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

/// One converted (Cadence 4.3) project in a temp folder, names copied from `.planning/_archive-v4/*/records` (D-10).
/// Each test asserts a path the app reads is still where 4.3 writes it (D-08). SUMMARY.md has no app reader.
@Suite struct ConvertedLayoutTests {
    private static let roadmapText = "# Roadmap: demo\n\n## Overview\n\nMilestone v5: Canopy-Foreman on Cadence. More text.\n\n## Phases\n"

    private func fixture() throws -> String {
        let root = NSTemporaryDirectory() + "cl-" + UUID().uuidString
        let planning = root + "/.planning"
        let phase = planning + "/phases/1"
        for dir in [planning + "/records", planning + "/debug", phase + "/records/reports"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let files: [String: String] = [
            planning + "/records/state.json": "{}",
            planning + "/ROADMAP.md": Self.roadmapText,
            planning + "/CAPTURE.md": "## Todos\n",
            planning + "/debug/open.md": "# Bug\nStatus: investigating\n",
            planning + "/debug/done.md": "# Bug\nStatus: resolved\n",
            phase + "/CONTEXT.md": "# Phase 1: x - Context\n",
            phase + "/PLAN-1.md": "# Plan 1\n",
            phase + "/PLAN-2.md": "# Plan 2\n",
            phase + "/UAT.md": "# UAT\n",
            phase + "/records/REVIEW-plan.md": "review\n",
            phase + "/records/reports/plan-1.md": "PLAN PARTIAL\n",
        ]
        for (path, text) in files { try text.write(toFile: path, atomically: true, encoding: .utf8) }
        return root
    }

    @Test func uatMdStaysAtThePhaseTop() throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project) }
        let loader = UATScreenLoader(status: { _, _ in .notStarted })
        let data = loader.load(project: project, phase: "1", worktree: nil)
        #expect(data.path == project + "/.planning/phases/1/UAT.md")
        #expect(data.file != nil)
    }

    @Test func contextAndPlanFilesStayAtThePhaseTop() throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project) }
        #expect(WorkflowStageMap.hasContext(project: project, phase: "1"))
        #expect(WorkflowStageMap.hasPlans(project: project, phase: "1"))
    }

    @Test func contextScreenOpensThePhaseTopContextMd() throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project) }
        let opened = Opened()
        let loader = ContextScreenLoader(read: { opened.add($0); return try? String(contentsOfFile: $0, encoding: .utf8) })
        let data = loader.load(project: project, phase: "1", worktree: nil)
        #expect(opened.all == [project + "/.planning/phases/1/CONTEXT.md"])
        #expect(data.source == .project)
    }

    @Test func debugFolderStaysUnderPlanning() throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project) }
        #expect(CadenceHealth.openDebugFiles(project: project) == .success(1))
    }

    @Test func captureMdStaysUnderPlanning() throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project) }
        #expect(MilestoneCapture.file(project: project, worktree: nil) == project + "/.planning/CAPTURE.md")
    }

    @Test func roadmapMilestoneLineStaysUnderOverview() throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project) }
        let text = try String(contentsOfFile: project + "/.planning/ROADMAP.md", encoding: .utf8)
        let status = CadenceStatus(current: "1", total: 1, cycle: nil, phases: [.init(n: "1", name: "x", status: "planned")], cursorNext: nil)
        #expect(WorkflowStageMap.milestoneName(roadmap: text, status: status) == "Milestone v5: Canopy-Foreman on Cadence")
    }
}
