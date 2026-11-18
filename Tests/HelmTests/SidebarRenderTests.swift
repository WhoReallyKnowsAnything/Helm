import AppKit
import SwiftUI
import Testing
@testable import Helm

/// Renders the sidebar pieces offscreen (no app launch) at the minimum and default sidebar widths and
/// writes PNGs to `screenshots/` for a visual check. The size checks fail if a piece gets taller than it needs
/// to be when wrapped, or if the renderer produces nothing.
@MainActor
struct SidebarRenderTests {
    static let out = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("screenshots")

    @discardableResult
    private func render<V: View>(_ view: V, width: CGFloat, name: String) throws -> NSSize {
        let host = NSHostingView(rootView: view.frame(width: width).background(Ink.sidebar).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: Self.out.appendingPathComponent("\(name).png"))
        return size
    }

    @Test(arguments: [200.0, 260.0])
    func sidebarPiecesRenderInFull(width: Double) throws {
        let now = Date()
        let usage = UsageState(
            fiveHour: UsageWindow(usedPercentage: 8, resetsAt: now.addingTimeInterval(3 * 3600), sampled: now),
            sevenDay: UsageWindow(usedPercentage: 45, resetsAt: now.addingTimeInterval(3 * 86400), sampled: now))
        let usageSize = try render(UsagePanelView(usage: usage, now: now), width: width, name: "usage-\(Int(width))")
        #expect(usageSize.height > 0)
        for w in [200.0, 260.0] {
            let plain = try render(UsagePanelView(usage: usage, now: now), width: w, name: "ctx-plain-\(Int(w))")
            let withCtx = try render(UsagePanelView(usage: usage, now: now, contextText: "Ctx: 42%"), width: w, name: "ctx-\(Int(w))")
            #expect(withCtx.height > plain.height)
        }
        #expect(UsagePanelView.contextLine(chatOpen: true, percent: 42) == "Ctx: 42%")
        #expect(UsagePanelView.contextLine(chatOpen: true, percent: 0) == "Ctx: 0%")
        #expect(UsagePanelView.contextLine(chatOpen: false, percent: 42) == nil)
        #expect(UsagePanelView.contextLine(chatOpen: true, percent: nil) == nil)

        let projectSize = try render(NewProjectView(store: SessionStore(runner: { TmuxOutcome.failed("") }), onStarted: { _ in }),
                                     width: width, name: "newproject-\(Int(width))")
        // The three kit buttons are one row at both widths (D-19 item 3).
        #expect(projectSize.height == Metric.newProjectRowMinHeight)
    }

    @Test func aResetWindowReadsZeroPercentAndAnAbsentOneHasNoLine() {
        let now = Date()
        let live = UsageWindow(usedPercentage: 8, resetsAt: now.addingTimeInterval(3600), sampled: now)
        let expired = UsageWindow(usedPercentage: 90, resetsAt: now.addingTimeInterval(-1), sampled: now)
        let lines = UsagePanelView.limitLines(UsageState(fiveHour: live, sevenDay: live), now: now)
        #expect(lines.allSatisfy { $0.contains("8% used  resets ") })
        #expect(UsagePanelView.limitLines(UsageState(fiveHour: expired, sevenDay: live), now: now).first == "5h  0% used")
        #expect(UsagePanelView.limitLines(UsageState(fiveHour: nil, sevenDay: expired), now: now) == ["7d  0% used"])
        #expect(UsagePanelView.limitLines(UsageState(), now: now) == ["usage: no data"])
    }

    @Test(arguments: [200.0, 260.0])
    func sidebarShowsDormantRowsAfterTheLiveOnes(width: Double) throws {
        let now = Date()
        let usage = UsageState(
            fiveHour: UsageWindow(usedPercentage: 8, resetsAt: now.addingTimeInterval(3 * 3600), sampled: now),
            sevenDay: UsageWindow(usedPercentage: 45, resetsAt: now.addingTimeInterval(3 * 86400), sampled: now))
        let sidebar = SidebarView(
            newProject: NewProjectView(store: SessionStore(runner: { TmuxOutcome.failed("") }), onStarted: { _ in }),
            rows: [SessionRow(id: "orch-7f3a", title: "project-one")],
            alertCounts: [:], selected: nil, usage: usage, now: now,
            failure: nil, onSelect: { _ in },
            dormant: [OpenProject(id: "orch-91bc", title: "project-two", folder: "/work/two"),
                      OpenProject(id: "orch-2d40", title: "project-three", folder: "/work/three")],
            onRemove: { _ in }, restore: { _ in }, restoring: "orch-2d40")
        let size = try render(sidebar.frame(height: 480), width: width, name: "sidebar-dormant-\(Int(width))")
        #expect(size.width > 0 && size.height > 0)
    }

    /// The size a view takes at a width (nil: its own ideal width), measured without writing a PNG.
    private func fitting<V: View>(_ view: V, width: CGFloat?) -> NSSize {
        let styled = view.background(Ink.sidebar).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: width.map { AnyView(styled.frame(width: $0)) } ?? AnyView(styled))
        host.frame = NSRect(x: 0, y: 0, width: width ?? 10, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func newProject(running: Bool?) -> NewProjectView {
        NewProjectView(store: SessionStore(runner: { TmuxOutcome.failed("") }), onStarted: { _ in }, runningOverride: running)
    }

    /// D-19 item 3: at the width where the full row just fits, only the "Starting" text can push it over, and a pushed row
    /// must not become a stack. The off render is one row, and the on render is one row too.
    @Test func theRunningTextDoesNotFlipTheRowToAStack() {
        let justFits = fitting(newProject(running: false), width: nil).width.rounded(.up)
        #expect(fitting(newProject(running: false), width: justFits).height == Metric.newProjectRowMinHeight)
        #expect(fitting(newProject(running: true), width: justFits).height == Metric.newProjectRowMinHeight)
    }

    /// AC13 (c): one row at the minimum, the default and a wide sidebar, with a start running and without.
    @Test(arguments: [200.0, 260.0, 400.0, 600.0], [false, true])
    func theThreeButtonsStayInOneRow(width: Double, running: Bool) {
        #expect(fitting(newProject(running: running), width: width).height == Metric.newProjectRowMinHeight)
    }

    /// The short row fits the minimum sidebar (200) inside its own padding, so the labels shorten and nothing stacks.
    @Test func theShortRowFitsTheMinimumSidebar() {
        let short = fitting(newProject(running: false).buttonRow(short: true, starting: false), width: nil).width
        #expect(short <= 200 - 2 * Space.sm)
    }

    private func png<V: View>(_ view: V, width: CGFloat) throws -> Data {
        let rep = try RenderSupport.render(view, .fixed(CGSize(width: width, height: Metric.newProjectRowMinHeight)))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// At a wide width the off render is the full-label row. The running text draws on top of it, still in one row.
    @Test func aWideSidebarShowsTheFullLabelsAndTheRunningText() throws {
        let width: CGFloat = 600
        let full = newProject(running: false).buttonRow(short: false, starting: false)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, minHeight: Metric.newProjectRowMinHeight, alignment: .leading)
        let off = try png(newProject(running: false), width: width)
        #expect(off == (try png(full, width: width)))
        #expect(try png(newProject(running: true), width: width) != off)
    }

    /// A press cannot change the row: a button forced to the pressed state measures the same as an unpressed one.
    @Test func aPressedKitButtonKeepsItsSize() {
        let plain = fitting(Button("+ New project") {}.buttonStyle(.kit), width: nil)
        let pressed = fitting(Button("+ New project") {}.buttonStyle(KitButtonStyle(forced: .pressed)), width: nil)
        #expect(plain == pressed)
    }
}
