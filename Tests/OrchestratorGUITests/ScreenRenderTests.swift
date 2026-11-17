import AppKit
import SwiftUI
import Testing
@testable import OrchestratorGUI

/// Renders each restyled screen offscreen from fixture data (D-11) into the git-ignored `screenshots/` folder.
/// A screen counts as drawn when its PNG exists and holds more than one colour.
@MainActor
struct ScreenRenderTests {
    /// The size of the main area of a window on a laptop screen.
    static let windowSize = CGSize(width: 1280, height: 800)

    private func drawn(_ rep: NSBitmapImageRep) {
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
        #expect(RenderSupport.distinctColours(rep) > 1)
    }

    @Test func emptyState() throws {
        drawn(try RenderSupport.write(EmptyStateView(), .fixed(Self.windowSize), name: "screen-01-empty-state"))
    }

    /// The sidebar at the minimum and the default width, with a selected row, a row with the alert dot, usage data
    /// and the status-line offer.
    @Test func sidebar() throws {
        let now = Date()
        let usage = UsageState(
            fiveHour: UsageWindow(usedPercentage: 8, resetsAt: now.addingTimeInterval(3 * 3600), sampled: now),
            sevenDay: UsageWindow(usedPercentage: 45, resetsAt: now.addingTimeInterval(3 * 86400), sampled: now))
        func sidebar(width: CGFloat) -> some View {
            SidebarView(
                newProject: NewProjectView(store: SessionStore(runner: { TmuxOutcome.failed("") }), onStarted: { _ in }),
                rows: [SessionRow(id: "orch-7f3a", title: "project-one"), SessionRow(id: "orch-91bc", title: "project-two"),
                       SessionRow(id: "orch-2d40", title: "a-long-project-name-that-needs-room")],
                alertCounts: ["orch-91bc": 1], selected: "orch-7f3a", usage: usage, now: now,
                failure: nil, onSelect: { _ in }
            ).frame(width: width)
        }
        let both = HStack(spacing: Space.lg) { sidebar(width: 200); sidebar(width: 260) }
        drawn(try RenderSupport.write(both, .fixed(CGSize(width: 476, height: 520)), name: "screen-02-sidebar"))
    }

    /// The tree screen's bar, the terminal screen's bar, and the terminal screen's bar when the project has no folder.
    @Test func dispatchBar() throws {
        func bar(back: Bool, actions: Bool, waiting: Int = 0, running: Int = 0) -> some View {
            DispatchBar(showsBack: back, showsActions: actions, waiting: waiting, running: running, onBack: {}, onClose: {})
        }
        let bars = VStack(spacing: Space.lg) {
            bar(back: false, actions: true, waiting: 2, running: 3)
            bar(back: true, actions: true, running: 3)
            bar(back: true, actions: false)
            rootBand()
            KitPromptBar(text: .constant(""), action: {})
            KitPromptBar(text: .constant("add the export"), action: {})
        }
        drawn(try RenderSupport.write(bars, .content(width: 760), name: "screen-03-dispatch-bar"))
    }

    private let root = NavigationState.none.selecting("home", root: true)

    /// The top band of a root session, built from the navigation state as `ContentView` builds it, with 2 waiting and 3 running in the tree.
    private func rootBand() -> some View {
        let counts = root.bandCounts(waiting: 2, running: 3)
        return DispatchBar(showsBack: root.canGoBack, showsActions: true, waiting: counts.waiting, running: counts.running,
                           onBack: {}, onClose: {})
    }

    private func bandPNG<V: View>(_ view: V) throws -> Data {
        try #require(RenderSupport.render(view, .content(width: 760)).representation(using: .png, properties: [:]))
    }

    /// D-17: a root band keeps Close and draws no Back and no counts.
    @Test func theRootBandDrawsCloseOnly() throws {
        func plain(back: Bool, waiting: Int, running: Int) -> some View {
            DispatchBar(showsBack: back, showsActions: true, waiting: waiting, running: running, onBack: {}, onClose: {})
        }
        let rootPNG = try bandPNG(rootBand())
        #expect(rootPNG == (try bandPNG(plain(back: false, waiting: 0, running: 0))))
        #expect(rootPNG != (try bandPNG(plain(back: true, waiting: 0, running: 0))))
        #expect(rootPNG != (try bandPNG(plain(back: false, waiting: 2, running: 3))))
    }

    @Test func theCountsLeaveOutAZeroAndPutWaitingFirst() {
        func text(_ waiting: Int, _ running: Int) -> [String] { DispatchBar.countParts(waiting: waiting, running: running).map(\.text) }
        #expect(text(2, 3) == ["2 waiting", "3 running"])
        #expect(text(0, 3) == ["3 running"])
        #expect(text(2, 0) == ["2 waiting"])
        #expect(text(0, 0).isEmpty)
    }

    @Test func theTopBandDrawsEachCountInItsStatusColour() throws {
        // Text anti-aliasing blurs the glyph edges, so a tolerance of 24/255 per channel finds the solid stems. The cyan and
        // the blue differ by more than 30 in two channels, so this tolerance still tells them apart.
        let tolerance: CGFloat = 24 / 255
        func has(_ colour: Color, waiting: Int, running: Int) throws -> Bool {
            let size = CGSize(width: 760, height: Metric.headerBar)
            let bar = DispatchBar(showsBack: false, showsActions: true, waiting: waiting, running: running, onBack: {}, onClose: {})
            let rep = try RenderSupport.render(bar, .fixed(size))
            let want = try #require(NSColor(colour).usingColorSpace(.sRGB))
            for x in rep.pixelsWide / 2..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if abs(c.redComponent - want.redComponent) <= tolerance, abs(c.greenComponent - want.greenComponent) <= tolerance,
                       abs(c.blueComponent - want.blueComponent) <= tolerance { return true }
                }
            }
            return false
        }
        #expect(try has(Ink.waiting, waiting: 2, running: 0))
        #expect(try !has(Ink.running, waiting: 2, running: 0))
        #expect(try has(Ink.running, waiting: 0, running: 3))
        #expect(try !has(Ink.waiting, waiting: 0, running: 3))
    }

    private func nameBand(name: String?, cue: Bool = false, waiting: Int = 0, running: Int = 0) -> some View {
        DispatchBar(showsBack: true, showsActions: true, waiting: waiting, running: running, sessionName: name, showsWaitingCue: cue,
                    onBack: {}, onClose: {})
    }

    /// D-18 bar 1: the session name and the waiting cue are drawn in the top band, and a long name truncates in one line
    /// before it pushes the counts off the right edge.
    @Test func theTopBandDrawsTheSessionNameAndTheWaitingCue() throws {
        #expect(try bandPNG(nameBand(name: "alpha")) != bandPNG(nameBand(name: nil)))
        #expect(try bandPNG(nameBand(name: "alpha", cue: true)) != bandPNG(nameBand(name: "alpha")))

        let long = String(repeating: "w", count: 200)
        #expect(try height(nameBand(name: long, waiting: 2, running: 3), width: 760) == Metric.headerBar)
        let rep = try RenderSupport.render(nameBand(name: long, waiting: 2, running: 3), .fixed(CGSize(width: 760, height: Metric.headerBar)))
        let tolerance: CGFloat = 24 / 255
        func colourDrawn(_ colour: Color) throws -> Bool {
            let want = try #require(NSColor(colour).usingColorSpace(.sRGB))
            for x in rep.pixelsWide / 2..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if abs(c.redComponent - want.redComponent) <= tolerance, abs(c.greenComponent - want.greenComponent) <= tolerance,
                       abs(c.blueComponent - want.blueComponent) <= tolerance { return true }
                }
            }
            return false
        }
        #expect(try colourDrawn(Ink.waiting))
        #expect(try colourDrawn(Ink.running))
    }

    /// An orchestrator and 4 workers, one of each status, a dependency line, a hold card with Approve and Deny,
    /// a note and the Reset button. The running worker has fresh tmux activity, so its line is the flowing one.
    @Test func tree() throws {
        let now = Date()
        let session = "orch-7f3a"
        let rows = [
            WorkerRow(agentId: "alpha", status: "running", taskTitle: "Add the export", lastEvent: nil),
            WorkerRow(agentId: "bravo", status: "blocked", taskTitle: "Push the branch", lastEvent: nil),
            WorkerRow(agentId: "charlie", status: "done", taskTitle: "Write the docs", lastEvent: nil),
            WorkerRow(agentId: "delta", status: "stalled", taskTitle: "Fix the flaky test", lastEvent: nil),
        ]
        let state = WorkerState(
            rows: rows, dependencies: [WorkerDependency(dependent: "charlie", upstream: "alpha")], missing: ["worktree_path"])
        let hold = GateHold(id: "h1", label: "bravo", hash: String(repeating: "a", count: 64), epoch: 100, state: .live,
                            command: "Bash: git push origin session/add-the-export --force-with-lease && gh pr create --title \"Add the export\" --body \"Adds the CSV export\"")
        let info = [WorkerTree.orchestratorKey: ["42% context", "Opus 4.7 · high"], "alpha": ["18% context", "Sonnet 5.5 · medium"]]
        let tree = WorkerTreeView(
            orchestratorTitle: "project-one", session: session, project: "/fixture/screen-04",
            log: ["alpha": .init(fold: SessionStatusFold(), modified: now)], now: now,
            nodeInfo: info, result: .loaded(state), failure: nil, holds: [hold], blockCover: BlockCover(), holdFailure: nil,
            card: { HoldStore.Card(command: $0.command, stateLine: nil, outcome: nil, showsButtons: true, enabled: true) },
            onDecide: { _, _ in }, retry: {}, onNodeTap: { _ in })
        drawn(try RenderSupport.write(tree, .fixed(CGSize(width: 1100, height: 720)), name: "screen-04-tree"))
    }

    /// A press on the resize handle of a wide node saves nothing (D-21). The base is the unwidened size, the shown one is wider, so no resize starts.
    @Test func aPressOnTheHandleOfAWideNodeStartsNoResize() {
        let base = TreeLayout.nodeSize
        let shown = TreeLayout.widened(["alpha": base], widths: ["alpha": 430], canvasWidth: 1100)["alpha"]!
        #expect(shown.width > base.width)
        #expect(!TreeLayout.resizeMayStart(own: base, drawn: shown))
    }

    /// A worker screen of the terminal tab. `cards` adds the hold card of a live hold above the pane.
    private func terminalScreen(target: String, worker: Bool, cards: Bool = false, height: CGFloat = 220) -> some View {
        let row = WorkerRow(agentId: "alpha", status: "running", taskTitle: "Add the export", lastEvent: nil)
        let strip = WorkerActionsView(
            actions: WorkerActions(row: row), onMerge: {}, onTeardown: {}, onMarkDone: {}, requestText: "sent",
            onMergeAnyway: {}, onRefresh: {})
        let hold = GateHold(id: "h1", label: "alpha", hash: String(repeating: "a", count: 64), epoch: 100, state: .live,
                            command: "Bash: git push origin main")
        let holdBar = ProjectHoldBar(holds: [hold], root: false).map {
            ProjectHoldBarView(
                bar: $0, card: { HoldStore.Card(command: $0.command, stateLine: nil, outcome: nil, showsButtons: true, enabled: true) },
                onDecide: { _, _ in })
        }
        return SessionScreen(
            target: target, actionsStrip: worker ? strip : nil,
            markDoneText: worker ? "Mark done failed (exit 1): the worktree has uncommitted changes" : nil,
            holdBar: cards ? holdBar : nil, conversation: ConversationHost(path: nil)
        )
        .frame(height: height)
    }

    /// 3 variants stacked: a worker with the actions strip and a mark-done failure line; the orchestrator; and a worker
    /// with a live hold, whose card sits above the conversation. No out log is given, so the conversation shows its notice.
    @Test func terminal() throws {
        let stack = VStack(spacing: Space.lg) {
            terminalScreen(target: "alpha", worker: true)
            terminalScreen(target: "dashboard", worker: false)
            terminalScreen(target: "alpha", worker: true, cards: true, height: 320)
        }
        drawn(try RenderSupport.write(stack, .fixed(CGSize(width: 760, height: 792)), name: "screen-05-terminal"))
    }

    /// A hold card above the pane spans the main area: its border sits within the padding of both edges at 1000 pt.
    @Test func theTerminalHoldCardSpansTheFullWidth() throws {
        let width: CGFloat = 1000
        let rep = try RenderSupport.render(
            terminalScreen(target: "alpha", worker: false, cards: true, height: 320),
            .fixed(CGSize(width: width, height: 320)))
        let want = try #require(NSColor(Ink.waiting).usingColorSpace(.sRGB))
        let tolerance: CGFloat = 24 / 255
        let scale = CGFloat(rep.pixelsWide) / width
        var xs: [Int] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if abs(c.redComponent - want.redComponent) <= tolerance, abs(c.greenComponent - want.greenComponent) <= tolerance,
                   abs(c.blueComponent - want.blueComponent) <= tolerance { xs.append(x) }
            }
        }
        let first = try #require(xs.min()), last = try #require(xs.max())
        #expect(CGFloat(first) / scale <= Space.sm + 2)
        #expect(CGFloat(last + 1) / scale >= width - Space.sm - 2)
    }

    /// The card shows: the same worker screen with a hold draws differently, and the same screen without one draws the same twice.
    @Test func theTerminalCardChangesTheWorkerScreen() throws {
        func png(cards: Bool) throws -> Data {
            let rep = try RenderSupport.render(
                terminalScreen(target: "alpha", worker: true, cards: cards, height: 320), .fixed(CGSize(width: 760, height: 320)))
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        #expect(try png(cards: false) == png(cards: false))
        #expect(try png(cards: true) != png(cards: false))
    }

    /// The height of a view at a width, in points (the bitmap is scaled by its backing scale).
    private func height<V: View>(_ view: V, width: CGFloat) throws -> CGFloat {
        let rep = try RenderSupport.render(view, .content(width: width))
        return CGFloat(rep.pixelsHigh) * width / CGFloat(rep.pixelsWide)
    }

    private static let finishedRow = WorkerRow(agentId: "alpha", status: "running", taskTitle: "Add the export", lastEvent: "done")

    private static func pullRequest(title: String) -> PullRequest {
        PullRequest(
            number: 12, url: "https://github.com/acme/app/pull/12", state: "OPEN", isDraft: false, reviewDecision: "", title: title,
            checks: ChecksSummary(passed: 3), files: (1...5).map { PullRequestFile(path: "Sources/File\($0).swift", additions: $0, deletions: 1) },
            changedFiles: 5)
    }

    private func strip(_ actions: WorkerActions, pullRequest: PullRequest? = nil, requestText: String? = nil) -> WorkerActionsView {
        WorkerActionsView(
            actions: actions, onMerge: {}, onTeardown: {}, onMarkDone: {}, pullRequest: pullRequest, requestText: requestText,
            onMergeAnyway: {}, onRefresh: {})
    }

    /// The heaviest bar 2: an open pull request with a long title and files, Merge locally anyway and Mark done both on, a request text.
    private func heaviestStrip() -> WorkerActionsView {
        let pr = Self.pullRequest(title: String(repeating: "A very long pull request title ", count: 4))
        var actions = WorkerActions(row: Self.finishedRow, pullRequest: .loaded(pr))
        actions.mergeAnywayEnabled = true
        actions.markDoneShown = true
        return strip(actions, pullRequest: pr, requestText: "The orchestrator refused the request.")
    }

    /// Whether every pixel in the left and right `Space.md` columns of `view`, above the bottom hairline, equals `Ink.header` alone.
    private func marginsAreEmpty<V: View>(_ view: V, width: CGFloat) throws -> Bool {
        let size = CGSize(width: width, height: Metric.dispatchBar)
        let actual = try RenderSupport.render(view, .fixed(size))
        let blank = try RenderSupport.render(Ink.header, .fixed(size))
        let scale = CGFloat(actual.pixelsWide) / width
        let margin = Int((Space.md * scale).rounded(.down))
        let rows = actual.pixelsHigh - Int((Metric.hairline * scale).rounded(.up)) - 1
        func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
            var value = [Int](repeating: 0, count: 5)
            rep.getPixel(&value, atX: x, y: y)
            return value
        }
        for y in 0..<rows {
            for x in Array(0..<margin) + Array((actual.pixelsWide - margin)..<actual.pixelsWide)
            where pixel(actual, x, y) != pixel(blank, x, y) {
                return false
            }
        }
        return true
    }

    /// Bar 2 is one bar in every state: the pull request text sits in the button row, not in a footer under it.
    @Test func theWorkerActionBarIsOneBarInEveryState() throws {
        let pr = Self.pullRequest(title: String(repeating: "A very long pull request title ", count: 4))
        let none = strip(WorkerActions(row: Self.finishedRow))
        let open = strip(WorkerActions(row: Self.finishedRow, pullRequest: .loaded(pr)), pullRequest: pr)
        let failed = strip(WorkerActions(row: Self.finishedRow, pullRequest: .failed("gh: not logged in")))
        for state in [none, open, failed] {
            #expect(try height(state, width: 760) == Metric.dispatchBar)
        }
        func png<V: View>(_ view: V) throws -> Data {
            try #require(RenderSupport.render(view, .content(width: 760)).representation(using: .png, properties: [:]))
        }
        #expect(try png(none) != png(failed))
    }

    /// No control is clipped or pushed into the margin at the minimum window with the default sidebar (495), with a wide
    /// sidebar (400), and at wider windows. At 400 the labels went icon-only, so it draws differently from 760.
    @Test func theWorkerActionBarKeepsItsMarginsAtNarrowWidths() throws {
        for width in [495.0, 400.0, 760.0, 1000.0] {
            #expect(try marginsAreEmpty(heaviestStrip(), width: width), "width \(width)")
        }
        func png(_ width: CGFloat) throws -> Data {
            try #require(RenderSupport.render(heaviestStrip(), .fixed(CGSize(width: width, height: Metric.dispatchBar)))
                .representation(using: .png, properties: [:]))
        }
        #expect(try png(400) != png(760))
    }

    /// AC12: the bars above the pane, composed as `ContentView.main` composes them, counted by their measured height.
    /// A worker has 2 (the top band and the action bar), a terminal with no strip has 1, and nothing else is fixed above the pane.
    @Test func aWorkerTerminalHasTwoHeaderBarsAboveThePane() throws {
        // The conversation with no out log draws its notice; measured alone, it is the pane's height.
        let pane = try height(ConversationHost(path: nil), width: 760)
        func screen(worker: Bool) -> some View {
            VStack(spacing: Space.none) {
                DispatchBar(showsBack: worker, showsActions: true, waiting: worker ? 1 : 0, running: worker ? 2 : 0,
                            sessionName: worker ? "alpha" : "dashboard", showsWaitingCue: worker, onBack: {}, onClose: {})
                SessionScreen(
                    target: worker ? "alpha" : "dashboard", actionsStrip: worker ? strip(WorkerActions(row: Self.finishedRow)) : nil,
                    markDoneText: nil, holdBar: nil, conversation: ConversationHost(path: nil))
            }
        }
        #expect(try height(screen(worker: true), width: 760) == Metric.headerBar + Metric.dispatchBar + pane)
        #expect(try height(screen(worker: false), width: 760) == Metric.headerBar + pane)
    }

    /// Several tasks with a subtask, one duplicate title and a failure line.
    @Test func dispatchSheet() throws {
        let now = Date()
        func task(_ id: String, _ title: String, status: String = "Not started", priority: String? = nil, parent: String? = nil) -> NotionTask {
            NotionTask(id: id, title: title, status: status, priority: priority, tags: [], url: nil, parentID: parent)
        }
        let list = TaskList(schema: 1, project: "project-one", generatedAt: now.addingTimeInterval(-300), tasks: [
            task("1", "Add the export", priority: "High"),
            task("2", "Fix the flaky test", status: "In progress"),
            task("3", "Fix the flaky test", priority: "Low"),
            task("4", "Write the docs"),
            task("5", "Document the export format", parent: "1"),
        ])
        let sheet = DispatchSheetContent(
            list: list, failure: "Could not read the task-list file: showing the last good list.", message: nil,
            isSending: false, now: now, onPick: { _ in }, onClose: {})
        drawn(try RenderSupport.write(sheet, .fixed(CGSize(width: 680, height: 560)), name: "screen-06-dispatch-sheet"))
    }

    /// Three states stacked: the preview with the unknown-pull-request note, a running merge, and a failed result.
    @Test func mergeSheet() throws {
        let output = "worker alpha: 3 commits ahead of main\nfast-forward possible\nno conflicts"
        func sheet(_ state: MergeModel.State, unknown: Bool = false) -> some View {
            MergeSheetContent(label: "alpha", state: state, unknownPullRequestAllowed: unknown, onConfirm: {}, onClose: {})
        }
        let failed = MergeModel.Outcome(
            verdict: .failed, status: 2, output: "error: merge stopped by a conflict in Sources/App.swift",
            detail: "The run stopped before the branch was merged.", notice: "The orchestrator pane did not get the notice.")
        let stack = VStack(spacing: Space.lg) {
            sheet(.preview(output: output, canConfirm: true), unknown: true)
            sheet(.running)
            sheet(.result(failed))
        }
        #expect(MergeSheetContent.isBusy(.running) && !MergeSheetContent.isBusy(.preview(output: "", canConfirm: false)))
        drawn(try RenderSupport.write(stack, .content(width: 680), name: "screen-07-merge-sheet"))
    }

    /// Four states stacked: the first question, a running teardown, the stronger question, and a failed result.
    @Test func teardownSheet() throws {
        func sheet(_ state: TeardownModel.State) -> some View {
            TeardownSheetContent(label: "alpha", state: state, onConfirm: {}, onConfirmKill: {}, onClose: {})
        }
        let failed = TeardownModel.Outcome(
            succeeded: false, killed: false, status: 1, output: "error: could not remove the worktree: a file is in use",
            detail: nil)
        let stack = VStack(spacing: Space.lg) {
            sheet(.asking)
            sheet(.running(kill: false))
            sheet(.askingKill(output: "alpha has 2 commits that are not merged into main"))
            sheet(.result(failed))
        }
        #expect(TeardownSheetContent.isBusy(.running(kill: true)) && !TeardownSheetContent.isBusy(.asking))
        drawn(try RenderSupport.write(stack, .content(width: 680), name: "screen-08-teardown-sheet"))
    }

    /// The New project sheet content with an empty name, a valid name and a choice, an invalid name with its rule line,
    /// a running create, a failure line, and the "already exists" failure with its Select project button.
    @Test func newProjectSheet() throws {
        func sheet(
            name: String, github: GithubChoice = .skip, failure: String? = nil, running: Bool = false, offer: Bool = false
        ) -> some View {
            NewProjectSheetContent(
                name: .constant(name), github: .constant(github), failure: failure, isRunning: running, onCreate: {}, onClose: {},
                offersSelect: offer)
        }
        let stack = VStack(spacing: Space.lg) {
            sheet(name: "")
            sheet(name: "my-app", github: .privateRepo)
            sheet(name: "-bad name")
            sheet(name: "my-app", github: .privateRepo, running: true)
            sheet(name: "my-app", failure: "git init failed in /Users/me/Documents/Projects/my-app")
            sheet(name: "my-app", failure: "my-app already exists in ~/Documents/Projects.", offer: true)
        }
        #expect(NewProjectSheetContent.canCreate(name: "alpha", isRunning: false))
        #expect(!NewProjectSheetContent.canCreate(name: "", isRunning: false))
        #expect(!NewProjectSheetContent.canCreate(name: ".x", isRunning: false))
        #expect(!NewProjectSheetContent.canCreate(name: "alpha", isRunning: true))
        drawn(try RenderSupport.write(stack, .content(width: 520), name: "screen-09-new-project"))
    }

    /// Both quit alerts, laid out in their own window and stacked in one PNG. The accessory lists several projects.
    @Test func quitAlert() throws {
        let names = ["alpha", "bravo", "charlie", "delta"]
        let snapshot = TmuxSnapshot(
            sessions: [],
            windows: names.map { WindowEntry(session: $0, name: "dashboard", path: "/work/\($0)", activity: nil, paneId: "%1") },
            rows: names.map { SessionRow(id: $0, title: $0) })
        let model = QuitModel(snapshot: snapshot) { _, _ in }
        model.setChecked("alpha", true)
        model.setChecked("charlie", true)
        let ask = QuitDialog.makeAskAlert(model: model)
        let failed = QuitDialog.makeFailureAlert([
            QuitFailure(title: "alpha", reason: "still busy"), QuitFailure(title: "charlie", reason: "no such session"),
        ])
        #expect(ask.buttons.map(\.title) == ["Quit", "Cancel"])
        #expect(failed.buttons.map(\.title) == ["OK"])
        #expect(ask.alertStyle == .warning && failed.alertStyle == .warning)

        func bitmap(_ alert: NSAlert) throws -> NSBitmapImageRep {
            alert.layout()
            let view = try #require(alert.window.contentView)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        let reps = [try bitmap(ask), try bitmap(failed)]
        let size = NSSize(width: reps.map(\.size.width).max() ?? 0, height: reps.map(\.size.height).reduce(0, +) + Space.lg)
        let image = NSImage(size: size, flipped: true) { _ in
            var top = CGFloat.zero
            for rep in reps {
                rep.draw(in: NSRect(origin: NSPoint(x: 0, y: top), size: rep.size))
                top += rep.size.height + Space.lg
            }
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let stacked = try #require(NSBitmapImageRep(data: tiff))
        drawn(stacked)
        try FileManager.default.createDirectory(at: RenderSupport.out, withIntermediateDirectories: true)
        try #require(stacked.representation(using: .png, properties: [:]))
            .write(to: RenderSupport.out.appendingPathComponent("screen-11-quit-alert.png"))
    }

    /// The Settings window content: the accent picker only, sized to its content.
    @Test func settings() throws {
        let rep = try RenderSupport.write(AppSettingsView().kitAccentRoot(), .content(width: nil), name: "screen-12-settings")
        drawn(rep)
        #expect(CGFloat(rep.pixelsWide) >= Metric.settingsWidth)
        // The Accent-only form renders 206 px high. A form collapsed to its scroll minimum would fall under 100 (D-10).
        #expect(rep.pixelsHigh >= 100)
    }
}
