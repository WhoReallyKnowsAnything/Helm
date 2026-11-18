import AppKit
import SwiftUI
import Testing
@testable import Helm

/// Renders the live shell with no project: the empty states of the real Execute, Run record and Milestone views, and an empty Board.
@MainActor
struct WorkflowShellRenderTests {
    private static let rows = [WorkflowBoard.Row(n: "5", name: "Workflow area redesign", display: .stage(.planned))]

    private func snap<V: View>(_ view: V, dark: Bool, name: String) throws -> NSBitmapImageRep {
        let size = ScreenRenderTests.windowSize
        let host = NSHostingView(rootView: AnyView(view.background(Ink.background).frame(width: size.width, height: size.height)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: RenderSupport.out, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: RenderSupport.out.appendingPathComponent("\(name).png"))
        return rep
    }

    @Test func emptyStatesOfTheRealTabsAndTheEmptyBoardAreDrawn() throws {
        let requests = RequestStore()
        let cases: [(name: String, rows: [WorkflowBoard.Row], phase: String, tab: String)] = [
            ("execute", Self.rows, "5", "execute"), ("run", Self.rows, "5", "run"),
            ("milestone", Self.rows, "5", "milestone"), ("board-empty", [], "", "board"),
        ]
        for c in cases {
            for dark in [false, true] {
                let view = WorkflowShellView(rows: c.rows, phase: c.phase, tab: c.tab, onPickPhase: { _ in }, onSelectTab: { _ in }) { tab in
                    switch tab {
                    case "execute":
                        ExecuteScreenView(phase: c.phase, project: nil, worktree: nil, overlay: nil, live: false,
                                          requests: requests, onClear: { _ in })
                    case "run": RunRecordView(project: nil)
                    case "milestone": MilestoneScreenView(project: nil, milestone: "", lastPhase: nil, requests: requests)
                    default: WorkflowBoardView(board: nil, failure: nil)
                    }
                }
                let rep = try snap(view, dark: dark, name: "phase6-shell-empty-\(c.name)-\(dark ? "dark" : "light")")
                #expect(rep.pixelsWide > 0 && RenderSupport.distinctColours(rep) > 1)
            }
        }
    }
}
