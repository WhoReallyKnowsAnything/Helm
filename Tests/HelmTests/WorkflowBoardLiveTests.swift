import AppKit
import CryptoKit
import SwiftUI
import Testing
@testable import Helm

/// The board over a real WorkflowStore and a real GateHold (D-02, D-11, D-13): overlays and hold marks come from the stores.
@MainActor
struct WorkflowBoardLiveTests {
    private let clock = Date()
    private static let reason = "no planning folder"

    private func row(_ label: String, _ status: String, worktree: String = "/p/.claude/worktrees/w") -> WorkerRow {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: nil,
                         worktreePath: worktree, createdAt: format.string(from: clock.addingTimeInterval(-3600)))
    }

    private func store(source: @escaping WorkflowSource, live: Set<String> = []) -> WorkflowStore {
        let clock = clock
        return WorkflowStore(
            source: source, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            labels: { _ in .success(live) }, planFiles: { _, _, _ in true }, now: { clock })
    }

    private func wait(_ done: () -> Bool) async {
        for _ in 0..<300 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func hold(label: String) throws -> GateHold {
        let op = Data("git commit -m live\n".utf8)
        let hash = SHA256.hash(data: op).map { String(format: "%02x", $0) }.joined()
        let pending = Data("\(label)\n\(hash)\n4242\n1\nx\n1700000000\n".utf8) + op
        return try #require(GateHold.parse(id: "hold-live", pending: pending, decision: nil, isHookLive: { _, _ in true }))
    }

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

    @Test func realStoreOverlaysAndALiveHoldDrawOnTheBoard() async throws {
        let shown = WorkflowBoardFixture.board
        let running = WorkflowDispatch.label(stage: .execute, phase: "3")
        let store = store(source: { _ in .success(shown) }, live: [running])
        store.point(at: "/p", base: "base")
        await wait { store.panel != nil }
        store.setRows([row(WorkflowDispatch.label(stage: .verify, phase: "2"), "running"),
                       row(running, "running"),
                       row(WorkflowDispatch.label(stage: .plan, phase: "5"), "done")])
        store.recomputeOverlays()
        await wait { store.overlays["5"]?.planReady == true }

        #expect(store.overlays["2"]?.state == .dead)
        #expect(store.overlays["3"]?.state == .running)
        #expect(store.overlays["5"]?.text == "Plan ready for review")

        let live = try hold(label: running)
        #expect(live.state == .live)
        #expect(!WorkflowBoardRows.holds([live], phase: "3").isEmpty)
        #expect(WorkflowBoardRows.holds([live], phase: "2").isEmpty)

        try FileManager.default.createDirectory(at: RenderSupport.out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let view = WorkflowBoardView(board: store.board, failure: store.failure, panel: store.panel,
                                         overlays: store.overlays, phase: "3", holds: [live])
            let rep = try snap(view, dark: dark)
            let url = RenderSupport.out.appendingPathComponent("phase2-live-board-\(dark ? "dark" : "light").png")
            try png(rep).write(to: url)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(rep.pixelsWide > 0 && RenderSupport.distinctColours(rep) > 1, "\(dark ? "dark" : "light") blank")
        }
    }

    @Test func aFailedRefreshGivesTheBoardOnlyTheReason() async throws {
        let store = store(source: { _ in .failure(.init(reason: Self.reason)) })
        store.point(at: "/p", base: "base")
        await wait { store.failure != nil }
        #expect(store.failure == Self.reason)
        #expect(store.board == nil)
        for dark in [false, true] {
            let fromStore = WorkflowBoardView(board: store.board, failure: store.failure)
            let nilBoard = WorkflowBoardView(board: nil, failure: Self.reason)
            #expect(try png(snap(fromStore, dark: dark)) == png(snap(nilBoard, dark: dark)))
        }
    }

    // D-10: progress comes from the board's own status, so the board sources run no Cadence call and read no disk.
    @Test func structuralBoardSourcesRunNoProcessAndReadNoDisk() throws {
        let words = ["ProcessRunner", "CadenceStatus.run", "FileManager", "contentsOfFile"]
        var matches = 0
        for name in ["WorkflowBoardRows", "WorkflowBoardView"] {
            let text = try String(contentsOfFile: "Sources/Helm/\(name).swift", encoding: .utf8)
            matches += words.filter { text.contains($0) }.count
        }
        #expect(matches == 0)
    }
}
