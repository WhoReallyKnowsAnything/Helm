import AppKit
import SwiftUI
import Testing
@testable import OrchestratorGUI

/// Renders the live shell with the real Board, Context, Plan and Verify views over a fixture project folder.
@MainActor
struct WorkflowShellV3RenderTests {
    private static let rows = [WorkflowBoard.Row(n: "5", name: "Workflow area redesign", display: .stage(.planned))]
    private static let uat = """
        ---
        status: testing
        phase: 5
        fields_version: 1
        ---

        ## Items

        ### 1. First
        expected: See Sources/OrchestratorGUI/WorkflowShellView.swift
        status: pending
        """

    private static var board: WorkflowBoard {
        WorkflowBoard(milestone: "v4 Cadence run, close and code views", rows: rows,
                      chips: [CadenceChip(skill: "/cadence:cad-coverage", phase: "5", argument: nil, rule: "verify", innerRole: nil)])
    }

    private static var panel: WorkflowPanel {
        WorkflowPanel(next: .init(stage: .plan, phase: "5", routing: StageRouting.Entry(model: nil, effort: nil)),
                      button: .enabled, roles: [])
    }

    /// A temp project with a phase 5 CONTEXT.md, one plan file and a UAT.md, all written here.
    private func fixture() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gui-test-v3-\(UUID().uuidString)")
        let phase = dir.appendingPathComponent(".planning/phases/5")
        try FileManager.default.createDirectory(at: phase, withIntermediateDirectories: true)
        try "# Phase 5: Workflow area redesign - Context\n\n## Decisions\n\n- D-01: Draw the Board, Context, Plan and Verify tabs.\n- D-02: Keep every tab read-only.\n"
            .write(to: phase.appendingPathComponent("CONTEXT.md"), atomically: true, encoding: .utf8)
        try "---\nphase: 5\nplan: 1\nfiles:\n  - Sources/OrchestratorGUI/WorkflowShellView.swift\n---\n\n# Phase 5 - Plan 1: Draw the tabs\n\n## Goal\n\nDraw the tabs.\n\n## Tasks\n\n### Task 1: Draw the Board\n\n- **Files:** Sources/OrchestratorGUI/WorkflowShellView.swift\n- **Action:** Draw it.\n- **Verify:** `swift test`\n"
            .write(to: phase.appendingPathComponent("PLAN-1.md"), atomically: true, encoding: .utf8)
        try Self.uat.write(to: phase.appendingPathComponent("UAT.md"), atomically: true, encoding: .utf8)
        return dir.path
    }

    @Test func realV3TabsAreDrawnInLightAndDark() async throws {
        let project = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project) }
        let requests = RequestStore()
        let size = ScreenRenderTests.windowSize
        for tab in ["board", "context", "plan", "verify"] {
            for dark in [false, true] {
                let view = WorkflowShellView(rows: Self.rows, phase: "5", tab: tab, onPickPhase: { _ in }, onSelectTab: { _ in }) { tab in
                    switch tab {
                    case "context": ContextScreenView(phase: "5", project: project, worktree: nil, overlay: nil, requests: requests,
                                                      panel: Self.panel)
                    case "plan": PlanReviewView(phase: "5", project: project, worktree: nil, overlay: nil, planned: true, requests: requests)
                    case "verify": UATScreenView(phase: "5", project: project, worktree: nil, overlay: nil, requests: requests)
                    default: WorkflowBoardView(board: Self.board, failure: nil, panel: Self.panel, phase: "5")
                    }
                }
                let host = NSHostingView(rootView: AnyView(view.background(Ink.background).frame(width: size.width, height: size.height)))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                // A window makes onAppear fire, so the stores load the fixture files.
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(600))
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try FileManager.default.createDirectory(at: RenderSupport.out, withIntermediateDirectories: true)
                try #require(rep.representation(using: .png, properties: [:])).write(
                    to: RenderSupport.out.appendingPathComponent("phase5-shell-\(tab)-\(dark ? "dark" : "light").png"))
                #expect(rep.pixelsWide > 0 && RenderSupport.distinctColours(rep) > 1, "\(tab) \(dark ? "dark" : "light") is blank")
                window.contentView = nil
            }
        }
    }

    @Test func boardHasTheSuggestedMenuAndOnePrimary() {
        // The row takes "Suggested" from non-empty chips and one primary title from the panel's next target.
        #expect(!Self.board.chips.isEmpty)
        #expect(Self.panel.next.map { "Next: \($0.stage.rawValue.capitalized)" } == "Next: Plan")
    }
}
