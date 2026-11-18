import AppKit
import SwiftUI
import Testing
@testable import Helm

/// Renders the live shell with the real Execute, Run record and Milestone views and the editor over a fixture project folder.
@MainActor
struct WorkflowShellLiveRenderTests {
    private static let rows = [WorkflowBoard.Row(n: "6", name: "Workflow redesign", display: .stage(.planned))]

    /// A temp project with a phase 6 CONTEXT.md, PLAN-1.md and ROADMAP.md written here, and one source file.
    private func fixture() throws -> (project: String, file: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gui-test-live-\(UUID().uuidString)")
        let phase = dir.appendingPathComponent(".planning/phases/6")
        try FileManager.default.createDirectory(at: phase, withIntermediateDirectories: true)
        try "# Phase 6: Workflow redesign - Context\n\n## Decisions\n\n- D-01: Show Execute, Run record and Milestone.\n- D-02: Keep every tab read-only.\n"
            .write(to: phase.appendingPathComponent("CONTEXT.md"), atomically: true, encoding: .utf8)
        try "---\nphase: 6\nplan: 1\nfiles:\n  - Sources/Demo.swift\n---\n\n# Phase 6 - Plan 1: Show the tabs\n\n## Goal\n\nShow the tabs.\n\n## Tasks\n\n### Task 1: Show Execute\n\n- **Files:** Sources/Demo.swift\n- **Action:** Show it.\n- **Verify:** `swift test`\n"
            .write(to: phase.appendingPathComponent("PLAN-1.md"), atomically: true, encoding: .utf8)
        try "# Roadmap: demo\n\n## Overview\n\nMilestone v4: Run, close and code views.\n\n## Phases\n\n- [ ] **Phase 6: Workflow redesign** - show the tabs\n"
            .write(to: dir.appendingPathComponent(".planning/ROADMAP.md"), atomically: true, encoding: .utf8)
        let source = dir.appendingPathComponent("Sources/Demo.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "struct Demo {\n    let value = 1\n}\n".write(to: source, atomically: true, encoding: .utf8)
        return (dir.path, source.path)
    }

    /// True when the top `points` rows of both images hold the same pixels.
    private static func sameTop(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, points: CGFloat) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let da = a.bitmapData, let db = b.bitmapData else { return false }
        let rows = Int(points * CGFloat(a.pixelsWide) / ScreenRenderTests.windowSize.width)
        return memcmp(da, db, rows * a.bytesPerRow) == 0
    }

    @Test func realTabsAndTheEditorAreDrawnInLightAndDark() async throws {
        let (project, file) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project) }
        let requests = RequestStore()
        let size = ScreenRenderTests.windowSize
        var executeShots: [Bool: NSBitmapImageRep] = [:]
        for tab in ["execute", "run", "milestone", "editor"] {
            for dark in [false, true] {
                let shellTab = tab == "editor" ? "execute" : tab
                let editor: AnyView? = tab == "editor"
                    ? AnyView(EditorView(path: file, line: 2, project: project)) : nil
                let holdBar: AnyView? = tab == "editor"
                    ? ProjectHoldBar(holds: [GateHold(id: "h1", label: "cad-execute-p6", hash: String(repeating: "a", count: 64), epoch: 100,
                                                      state: .live, command: "Bash: git push")], root: false).map {
                        AnyView(ProjectHoldBarView(bar: $0, card: { hold in
                            HoldStore.Card(command: hold.command, stateLine: nil, outcome: nil, showsButtons: true, enabled: true)
                        }, onDecide: { _, _ in }))
                    } : nil
                let view = WorkflowShellView(rows: Self.rows, phase: "6", tab: shellTab, onPickPhase: { _ in }, onSelectTab: { _ in },
                                             editor: editor, holdBar: holdBar) { current in
                    switch current {
                    case "run": RunRecordView(project: project, rows: Self.rows)
                    case "milestone": MilestoneScreenView(project: project, milestone: "v4", lastPhase: 6, requests: requests)
                    default: ExecuteScreenView(phase: "6", project: project, worktree: nil, overlay: nil, live: false,
                                               requests: requests, onClear: { _ in })
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
                    to: RenderSupport.out.appendingPathComponent("phase6-shell-\(tab)-\(dark ? "dark" : "light").png"))
                #expect(rep.pixelsWide > 0 && RenderSupport.distinctColours(rep) > 1, "\(tab) \(dark ? "dark" : "light") is blank")
                if tab == "execute" { executeShots[dark] = rep }
                if tab == "editor" {
                    // The header and tab bar sit above the hold bar and the editor, so they match the Execute shot's.
                    let execute = try #require(executeShots[dark])
                    #expect(Self.sameTop(rep, execute, points: 60), "the tab bar is not shown with the editor open")
                }
                window.contentView = nil
            }
        }
    }
}
