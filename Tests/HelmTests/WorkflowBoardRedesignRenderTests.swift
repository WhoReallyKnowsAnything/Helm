import AppKit
import SwiftUI
import Testing
@testable import Helm

/// Draws the redesigned Board over the fixture in light and dark (D-05, D-14). The PNGs go to the user for approval.
@MainActor
struct WorkflowBoardRedesignRenderTests {
    private func snap<V: View>(_ view: V, dark: Bool) throws -> NSBitmapImageRep {
        let size = ScreenRenderTests.windowSize
        let host = NSHostingView(rootView: AnyView(view.background(Ink.background).frame(width: size.width, height: size.height)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func png(_ rep: NSBitmapImageRep) throws -> Data {
        try #require(rep.representation(using: .png, properties: [:]))
    }

    private var fixtureView: some View {
        WorkflowShellView(rows: WorkflowBoardFixture.rows, phase: "5", tab: "board", onPickPhase: { _ in }, onSelectTab: { _ in }) { _ in
            WorkflowBoardView(board: WorkflowBoardFixture.board, failure: nil, panel: WorkflowBoardFixture.panel,
                              overlays: WorkflowBoardFixture.overlays, phase: "5",
                              executePhases: WorkflowBoardFixture.executePhases, holds: WorkflowBoardFixture.holds)
        }
    }

    // The app is dark only (`preferredColorScheme(.dark)`, fixed tokens), so the two PNGs are expected to match.
    @Test func fixtureBoardIsDrawnInLightAndDark() throws {
        try FileManager.default.createDirectory(at: RenderSupport.out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let rep = try snap(fixtureView, dark: dark)
            let data = try png(rep)
            try data.write(to: RenderSupport.out.appendingPathComponent("phase2-board-\(dark ? "dark" : "light").png"))
            #expect(rep.pixelsWide > 0 && RenderSupport.distinctColours(rep) > 1, "\(dark ? "dark" : "light") blank")
        }
    }

    @Test func fixtureCoversTheRowsTheUserReviews() {
        let rows = WorkflowBoardFixture.board.rows
        #expect(Set(rows.map { "\($0.display)" }).count >= 3)
        #expect(rows.map(\.n) == rows.map(\.n).sorted())
        #expect(WorkflowBoardFixture.overlays.values.contains { $0.state == .dead })
        #expect(WorkflowBoardFixture.holds.contains { $0.state == .live })
        #expect(WorkflowBoardFixture.panel.overrideReason != nil)
    }

    @Test func aFailureStillDrawsOnlyTheReasonLine() throws {
        for dark in [false, true] {
            let withBoard = WorkflowBoardView(board: WorkflowBoardFixture.board, failure: "no planning folder")
            let without = WorkflowBoardView(board: nil, failure: "no planning folder")
            #expect(try png(snap(withBoard, dark: dark)) == png(snap(without, dark: dark)))
        }
    }
}
