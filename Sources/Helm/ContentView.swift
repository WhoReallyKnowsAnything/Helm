import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SessionStore
    /// A banner click sets its pending-focus request. This view selects the node and clears it.
    @ObservedObject var alerts: AlertStore
    /// The worker to select once the rows of its project are loaded. Dropped when another project is selected.
    @State private var focus: FocusRequest?
    @StateObject private var workers = WorkerStore()
    /// The selected project's Cadence workflow board, pointed at the same folder as `workers`.
    @StateObject private var workflow = WorkflowStore()
    /// The selected project's gate holds (D-14), pointed at the same folder as `workers`.
    @StateObject private var holds = HoldStore()
    /// The selected project's open permission requests (D-07), fed from the workers' out-log paths.
    @StateObject private var requests = RequestStore()
    /// The turn state and write time of each node's out log (D-01, D-05), followed for the selected project.
    @StateObject private var logStatus = SessionStatusStore()
    /// The out-log paths of every open project, for the account usage (D-15).
    @StateObject private var openLogs = OpenProjectLogs()
    /// The selected project's task-list file (D-12), pointed at the same folder as `workers`.
    @StateObject private var tasks = TaskListStore()
    @State private var dispatchOpen = false
    /// Bumped by Clear so the terminal pane rebuilds on the fresh shell.
    @State private var shellEpoch = 0
    /// The Merge and Teardown sheets live here, never in the worker strip: the strip leaves the screen when
    /// `selectedWorker` is cleared, and a sheet inside it would be dismissed in the middle of a run.
    @State private var mergeModel: MergeModel?
    @State private var teardownModel: TeardownModel?
    /// The selected worker's pull request (D-15). It looks up on select, on finish and on Refresh, never on a timer.
    @StateObject private var pullRequests = PullRequestStore()
    /// The "ask the orchestrator to merge" request of the selected worker (D-05).
    @StateObject private var prRequest = PRMergeRequest()
    /// G3 (D-06): the selected `cad-verify-p<N>` worker's UAT verdict. Not gated for every other label.
    @StateObject private var uatGate = UATGateStore()
    /// G3 override (D-09): the capture request to a live verify worker and the grant after its fresh done mark.
    @StateObject private var overrideStore = UATOverrideStore()
    /// A complete UAT with skipped items asks first (D-08); `proceed` runs only on the confirm button.
    @State private var skippedConfirm: SkippedConfirm?
    private struct SkippedConfirm {
        var count: Int
        var proceed: () -> Void
    }
    /// True while a Mark done run is going, so a second press does nothing. `markDoneText` is the failure line under the strip.
    @State private var markingDone = false
    @State private var markDoneText: String?
    /// The blocks that a live hold already covered, for the selected project only (D-09). Reset when the project changes.
    @State private var blockCover = BlockCover()
    /// The account's 5-hour and 7-day limits, merged from the followed out logs (D-15). Held across updates.
    @State private var usage = UsageState()
    @State private var nav = NavigationState.none
    /// The per-project Close flow: a confirm alert, then `ProjectTeardown`, then the row leaves the sidebar.
    @StateObject private var closer = CloseModel(
        teardown: { id, folder in
            try await ProjectTeardown.stopOffMain(folder: folder, sessionId: id)
            await ShellStore.shared.close(folder)
        },
        forget: { OpenProjects.shared.remove($0) })
    /// Projects that were open, kept in a file so a restart or tmux stop leaves them in the sidebar (D-01).
    @ObservedObject private var openProjects = OpenProjects.shared
    /// The sidebar's "Remove all not running…" asks here first.
    @State private var confirmingRemoveAll = false
    /// The per-project Restore press (D-02, D-03). Only the dormant row's button calls `press`. The store refresh runs
    /// in the button's task below, since a `@StateObject` initializer cannot reach `store`.
    @StateObject private var restorer = RestoreModel(
        capture: { EnvironmentCapture.fileText(try EnvironmentCapture.capture()) },
        restore: { folder, envText in try await ProjectRestorer.restoreOffMain(folder: folder, envText: envText) },
        refresh: {})
    private var selection: String? { nav.project }
    /// The worker whose terminal shows. nil on the tree and for the orchestrator.
    private var selectedWorker: String? { nav.workerLabel }
    @AppStorage("sidebarWidth") private var sidebarWidth = 260.0

    var body: some View {
        HStack(spacing: Space.none) {
            sidebar.frame(width: min(max(sidebarWidth, 200), 600))
            KitSplitter(size: $sidebarWidth, range: 200...600)
            main
        }
        .background(Ink.background)
        .overlay(alignment: .top) { Ink.border.frame(height: Metric.hairline) }
        .frame(minWidth: Metric.windowMinWidth, minHeight: Metric.windowMinHeight)
        .onAppear {
            StartupTiming.logFirstWindow()
            store.start()
            openLogs.follow(openProjects.records.map(\.folder))
            applyFocus()
            BackMenu.shared.back = { if nav.canGoBack { nav = nav.goingBack() } }
        }
        .onChange(of: nav.canGoBack, initial: true) { BackMenu.shared.canGoBack = nav.canGoBack }
        .onChange(of: alerts.pendingFocus) { applyFocus() }
        .onChange(of: selection) {
            if focus?.projectId != selection { focus = nil }
        }
        // Not `snapshot.windows`: a worker that waits at a prompt leaves the window list unchanged, so only the tick reaches it.
        .onChange(of: store.tick) {
            // shortcut: a refresh in flight while a Close finishes can record the project again, so Close is pressed twice; the window is under 2 s.
            openProjects.record(store.snapshot)
            updateUsage()
        }
        // A worker that merged, died or hid sends its terminal back to the tree, so the area never shows a node that no longer draws.
        .onChange(of: selectedRow) { if selectedRow == nil, nav.workerLabel != nil { nav = nav.showingTree() } }
        .onChange(of: selectedWorker) { syncPullRequest() }
        .onChange(of: selectedRow) { syncUATGate() }
        // The worker turned finished while it stayed selected: look up again (D-15). A newly selected worker already has its own lookup.
        .onChange(of: finishedSelection) { old, new in
            if new.worker != nil, old.worker == new.worker, !old.finished, new.finished { pullRequests.refresh() }
        }
        .onChange(of: projectFolder) {
            syncPullRequest()
            blockCover = BlockCover()
            workers.point(at: projectFolder)
            workflow.point(at: projectFolder, base: selection)
            holds.point(at: projectFolder)
            if let id = selection, isRoot(id) { syncRequests() }
            else { requests.setSessions(RequestSessions.others(openLogs.states, excluding: projectFolder)) }
            tasks.point(at: projectFolder)
        }
        .onChange(of: workers.result) {
            updateBlockCover()
            selectFocusedWorker()
            syncRequests()
            if case .loaded(let loaded) = workers.result { workflow.setRows(loaded.rows) }
            syncOverride()
        }
        .onChange(of: workflow.endedLabels) { syncOverride() }
        .onAppear { overrideStore.onGranted = { overrideGranted($0) } }
        .onChange(of: requests.entries) {
            workflow.setPendingQuestions(requests.pendingQuestionLabels)
        }
        .onChange(of: store.snapshot.windows) { syncRequests(); workflow.recheckLive(); workflow.recomputeOverlays() }
        .onChange(of: openProjects.records) { openLogs.follow(openProjects.records.map(\.folder)) }
        .onChange(of: openLogs.paths) { followLogs() }
        .onChange(of: openLogs.states) { syncRequests() }
        .onChange(of: logStatus.entries) { updateUsage() }
        .onChange(of: holds.holds) { updateBlockCover() }
        .sheet(item: $mergeModel) { model in MergeSheet(model: model, onClose: { mergeModel = nil }) }
        .sheet(item: $teardownModel) { model in TeardownSheet(model: model, onClose: { teardownModel = nil }) }
    }

    /// D-11: the will-run callback of each model shows the tree, so the worker's terminal view is dismantled
    /// before tmux ends its window and no "Session ended" or "no live window" notice appears.
    /// `unknownPullRequestAllowed` is true only for "Merge locally anyway". Confirm always runs a fresh lookup first (D-05),
    /// because the store can be older than a pull request that someone opened since.
    private func startMerge(_ row: WorkerRow, base: String, unknownPullRequestAllowed: Bool = false) {
        guard let folder = projectFolder else { return }
        let label = row.agentId, worktree = row.worktreePath
        var gate: (@Sendable () -> UATGate.Verdict)?
        if UATGate.phase(ofLabel: label) != nil, !overrideStore.granted.contains(label) {
            gate = { UATGateCheck().run(project: folder, row: row) }
        }
        mergeModel = MergeModel(
            label: label, title: row.taskTitle, folder: folder, base: base, willRun: { nav = nav.showingTree() },
            pullRequestCheck: { PullRequestLookup.find(folder: folder, label: label, worktree: worktree) },
            unknownPullRequestAllowed: unknownPullRequestAllowed, uatGate: gate)
    }

    /// Points the store at the selected worker, or clears it when none is selected or the project has no folder.
    private func syncPullRequest() {
        prRequest.reset()
        markDoneText = nil
        syncUATGate()
        guard let folder = projectFolder, let label = selectedWorker else {
            pullRequests.clear()
            return
        }
        let worktree = selectedRow?.worktreePath
        pullRequests.select(lookup: { PullRequestLookup.find(folder: folder, label: label, worktree: worktree) })
    }

    /// Points the G3 store at the selected worker's row, or clears it.
    private func syncUATGate() {
        uatGate.point(project: selectedWorker == nil ? nil : projectFolder, row: selectedRow)
    }

    /// Every merge route goes through the G3 press decision: stop shows the reason, confirm asks about the skipped items.
    private func gatedPress(_ proceed: @escaping () -> Void) {
        switch UATGate.press(uatGate.effective(granted: overrideStore.granted)) {
        case .proceed: proceed()
        case .confirm(let count): skippedConfirm = SkippedConfirm(count: count, proceed: proceed)
        case .stop(let reason): markDoneText = "Merge is off: \(reason)"
        }
    }

    /// Checks G3 once more right before the request line is typed, so a UAT that turned partial since the press sends nothing.
    private func sendRequest(_ row: WorkerRow, held: PullRequest, base: String) async {
        if UATGate.phase(ofLabel: row.agentId) != nil, !overrideStore.granted.contains(row.agentId) {
            guard let folder = projectFolder else { return }
            let verdict = await Task.detached { UATGateCheck().run(project: folder, row: row) }.value
            if case .stop(let reason) = UATGate.press(verdict) {
                markDoneText = "Merge is off: \(reason)"
                return
            }
        }
        await prRequest.send(number: held.number, label: row.agentId, title: row.taskTitle, base: base)
    }

    /// The Merge button of the strip. An "ask" press acts only if the store still holds that open pull request (D-05).
    private func pressMerge(_ row: WorkerRow, base: String, kind: WorkerActions.MergeKind) {
        switch kind {
        case .local:
            gatedPress { startMerge(row, base: base) }
        case .askOrchestrator(let number):
            guard case .loaded(let held?) = pullRequests.state, held.isOpen, held.number == number else { return }
            gatedPress { Task { await sendRequest(row, held: held, base: base) } }
        }
    }

    /// Records `done` for the worker off the main actor, then reads the rows again so the D-04 guard re-evaluates.
    private func pressMarkDone(_ row: WorkerRow) {
        guard !markingDone else { return }
        markingDone = true
        markDoneText = nil
        let label = row.agentId, worktree = row.worktreePath
        Task {
            let run = await Task.detached {
                do {
                    return MergeReview.markDone(label: label, worktree: worktree, environment: try MergeReview.environment())
                } catch {
                    let reason = error.localizedDescription
                    return MergeReview.Run(output: reason, status: -1, failure: .didNotStart(reason))
                }
            }.value
            markingDone = false
            if selectedWorker == label { markDoneText = WorkerActions.markDoneFailure(run) }
            workers.requestRead()
        }
    }

    /// The pull request the store holds now, if it holds one.
    private var heldPullRequest: PullRequest? {
        if case .loaded(let held) = pullRequests.state { return held }
        return nil
    }

    private var requestText: String? {
        switch prRequest.state {
        case .idle: return nil
        case .sending: return "Sending the request"
        case .sent(let text), .refused(let text): return text
        }
    }

    /// The selected worker and whether its row passes the D-04 test, so a change to finished can be told from a new selection.
    private struct FinishedSelection: Equatable {
        var worker: String?
        var finished: Bool
    }

    private var finishedSelection: FinishedSelection {
        FinishedSelection(worker: selectedWorker, finished: selectedRow.map(MergeModel.isFinished) ?? false)
    }

    private func startTeardown(_ row: WorkerRow) {
        guard let folder = projectFolder else { return }
        teardownModel = TeardownModel(label: row.agentId, folder: folder, willRun: { nav = nav.showingTree() })
    }

    /// D-13: the `dashboard` window's path in the selected base session. No git lookup, no walk-up.
    /// The worktree of the phase's `cad-context-p<N>` worker row. The loader reads it only while it exists.
    private func contextWorktree(_ phase: String) -> String? {
        guard case .loaded(let state) = workers.result else { return nil }
        let label = WorkflowDispatch.label(stage: .context, phase: phase)
        return state.rows.last { $0.agentId == label && $0.worktreePath != nil }?.worktreePath
    }

    /// The worktree of the phase's `cad-verify-p<N>` worker row. The loader reads it only while it exists.
    private func uatWorktree(_ phase: String) -> String? {
        guard case .loaded(let state) = workers.result else { return nil }
        let label = WorkflowDispatch.label(stage: .verify, phase: phase)
        return state.rows.last { $0.agentId == label && $0.worktreePath != nil }?.worktreePath
    }

    /// The worktree of the last phase's `cad-milestone-p<N>` worker row.
    private func milestoneWorktree() -> String? {
        guard case .loaded(let state) = workers.result, let last = workflow.board?.status?.phases.last else { return nil }
        let label = WorkflowDispatch.label(stage: .milestone, phase: last.n)
        return state.rows.last { $0.agentId == label && $0.worktreePath != nil }?.worktreePath
    }

    private func executeWorktree(_ phase: String) -> String? {
        guard case .loaded(let state) = workers.result else { return nil }
        let label = WorkflowDispatch.label(stage: .execute, phase: phase)
        return state.rows.last { $0.agentId == label && $0.worktreePath != nil }?.worktreePath
    }

    /// The inbox path of the phase's `cad-verify-p<N>` worker row, nil when it has none.
    private func uatInbox(_ phase: String) -> String? {
        guard case .loaded(let state) = workers.result else { return nil }
        let label = WorkflowDispatch.label(stage: .verify, phase: phase)
        return state.rows.last { $0.agentId == label }?.inboxPath
    }

    /// Current value of `review.triggers.plan.gate` from the board's config check, nil when unreadable.
    private var planGate: String? {
        guard case .success(let check)? = workflow.board?.configCheck else { return nil }
        return check.rows.first { $0.key == PlanReviewActions.gateKey }?.current?.text
    }

    private var loadedRows: [WorkerRow] {
        guard case .loaded(let state) = workers.result else { return [] }
        return state.rows
    }

    /// Approve on the plan screen: the same merge sheet as the worker strip, with its own preview and Confirm.
    private func approvePlan(_ label: String) {
        guard let id = selection, case .loaded(let state) = workers.result,
              let row = state.rows.last(where: { $0.agentId == label }) else { return }
        startMerge(row, base: id)
    }

    private var editorRows: [WorkerRow] {
        if case .loaded(let state) = workers.result { return state.rows }
        return []
    }

    private func planWorktree(_ phase: String) -> String? {
        guard case .loaded(let state) = workers.result else { return nil }
        let label = WorkflowDispatch.label(stage: .plan, phase: phase)
        return state.rows.last { $0.agentId == label && $0.worktreePath != nil }?.worktreePath
    }

    private var projectFolder: String? {
        guard let id = selection else { return nil }
        return store.snapshot.windows.first { $0.session == id && $0.name == "dashboard" }?.path
    }

    /// Takes the banner click: selects its project, then clears the request. Only a project that is still in the
    /// sidebar counts. The worker's terminal opens once the rows are loaded, because the project change resets the rows.
    private func applyFocus() {
        guard let request = alerts.pendingFocus else { return }
        alerts.pendingFocus = nil
        guard store.rows.contains(where: { $0.id == request.projectId }) else { return }
        focus = request
        if selection == request.projectId { selectFocusedWorker() } else { nav = nav.selecting(request.projectId, root: isRoot(request.projectId)) }
    }

    /// D-17: the row is a root session, so it opens as a terminal. False when the row is not listed.
    private func isRoot(_ id: String) -> Bool { store.rows.first { $0.id == id }?.isRootSession ?? false }

    /// Opens the focused worker's terminal, with the waiting cue, when its project is the selected one and the tree draws that worker.
    private func selectFocusedWorker() {
        guard let request = focus, let id = selection, request.projectId == id, case .loaded(let state) = workers.result,
              state.rows.contains(where: {
                  $0.agentId == request.label && WorkerStatusRules.status(of: $0, lastWrite: log[$0.agentId]?.modified, now: Date()) != nil
              })
        else { return }
        nav = nav.openingFromHoldBanner(project: id, label: request.label)
        focus = nil
    }

    private func updateBlockCover() {
        guard case .loaded(let state) = workers.result else { return }
        blockCover.update(rows: state.rows, holds: holds.holds)
    }

    private func paneState(_ id: String?) -> PaneState {
        SessionListing.paneState(selected: id, rows: store.rows, processExited: false)
    }

    /// The selected worker's database row, only while the tree still draws it (D-06). Its raw status feeds the D-17 rule.
    private var selectedRow: WorkerRow? {
        guard let agent = selectedWorker, selection != nil, case .loaded(let state) = workers.result else { return nil }
        return state.rows.first {
            $0.agentId == agent && WorkerStatusRules.status(of: $0, lastWrite: log[$0.agentId]?.modified, now: Date()) != nil
        }
    }

    /// The lines under each node, built from the tree's nodes and the current samples.
    private func nodeInfo(session id: String) -> [String: [String]] {
        let now = Date()
        var state: WorkerState?
        if case .loaded(let loaded) = workers.result { state = loaded }
        let tree = WorkerTree(orchestratorTitle: id, state: state, log: log, now: now, deadLabels: workflow.deadLabels)
        return NodeInfo.lines(log: log, nodes: tree.nodes, rows: state?.rows ?? [])
    }

    /// The window the panel shows: the selected worker's label, else the orchestrator's `dashboard`.
    private var target: String { selectedWorker ?? "dashboard" }

    /// Base gone, or no live worker window: the conversation shows as ended and its prompt box is disabled.
    private func gone(_ id: String) -> Bool {
        if paneState(id) == .ended { return true }
        if let worker = selectedWorker {
            return !SessionListing.workerTerminalEnabled(label: worker, status: selectedRow?.status ?? "", windows: store.snapshot.windows, session: id)
        }
        return false
    }

    /// The alert counts plus each other project's open requests, so a question that waits shows on its sidebar row.
    private var alertCounts: [String: Int] {
        var counts = alerts.counts
        let pending = requests.pendingByProject
        for window in store.snapshot.windows where window.name == "dashboard" {
            if let n = pending[window.path] { counts[window.session, default: 0] += n }
        }
        return counts
    }

    private var sidebar: some View {
        SidebarView(
            newProject: NewProjectView(store: store) { id in nav = nav.selecting(id, root: isRoot(id)) },
            rows: store.rows, alertCounts: alertCounts, selected: selection,
            usage: usage, now: Date(),
            failure: store.failure, onSelect: { nav = nav.clickingSidebarRow($0, root: isRoot($0)) },
            // Before the first refresh every live project would flash as dormant.
            dormant: store.tick > 0 ? openProjects.dormant(excluding: store.rows) : [],
            onRemove: { openProjects.remove($0) },
            onRemoveAll: { confirmingRemoveAll = true },
            restore: { project in Task { await restorer.press(project); await store.refresh() } },
            restoring: restorer.running,
            contextText: UsagePanelView.contextLine(
                chatOpen: nav.terminalLabel != nil,
                percent: outLogPath().flatMap { logStatus.entries[$0]?.fold.contextPercent }),
            homeSelected: nav.showsHomeShell,
            onHome: { nav = nav.openingHomeShell() }
        )
        .alert(
            "Could not restore \(restorer.failure?.title ?? "")",
            isPresented: Binding(get: { restorer.failure != nil }, set: { if !$0 { restorer.dismissFailure() } })
        ) {
            Button("OK") {}
        } message: {
            Text(restorer.failure?.reason ?? "")
        }
        .alert(
            restorer.notice?.title ?? "",
            isPresented: Binding(get: { restorer.notice != nil }, set: { if !$0 { restorer.dismissNotice() } })
        ) {
            Button("OK") {}
        } message: {
            Text(restorer.notice?.reason ?? "")
        }
        .alert(
            "Close \(closer.pending?.title ?? "")?",
            isPresented: Binding(get: { closer.pending != nil }, set: { if !$0 { closer.cancel() } })
        ) {
            Button("Close", role: .destructive) {
                let request = closer.take()
                Task {
                    guard let id = await closer.confirm(request) else { return }
                    if selection == id { nav = nav.deselected() }
                    await store.refresh()
                }
            }
            .accessibilityIdentifier("close-project-confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("close-project-cancel")
        } message: {
            Text(closer.pending?.message ?? "")
        }
        .alert(
            "Could not close \(closer.failure?.title ?? "")",
            isPresented: Binding(get: { closer.failure != nil }, set: { if !$0 { closer.dismissFailure() } })
        ) {
            Button("OK") {}
        } message: {
            Text(closer.failure?.reason ?? "")
        }
        .alert(
            "Remove \(openProjects.dormant(excluding: store.rows).count) projects from the list?",
            isPresented: $confirmingRemoveAll
        ) {
            // Ids are read at confirm time against the live rows, so a running project is never removed.
            Button("Remove", role: .destructive) { openProjects.remove(openProjects.dormant(excluding: store.rows).map(\.id)) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            skippedConfirm.map { UATGateStore.skippedConfirmation($0.count) } ?? "",
            isPresented: Binding(get: { skippedConfirm != nil }, set: { if !$0 { skippedConfirm = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Merge Anyway") {
                let go = skippedConfirm?.proceed
                skippedConfirm = nil
                go?()
            }
        }
    }

    @ViewBuilder private var main: some View {
        if case .shell(let folder, _) = nav.screen, nav.showsHomeShell {
            VStack(spacing: Space.none) {
                DispatchBar(showsBack: true, showsActions: false, onBack: { nav = nav.goingBack() },
                            showsClear: true, onClear: { ShellStore.shared.close(folder); shellEpoch += 1 }, onClose: {})
                ShellPane(folder: folder).id("shell-\(folder)-\(shellEpoch)").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let id = selection {
            VStack(spacing: Space.none) {
                if projectFolder != nil || nav.canGoBack { dispatchBar(id) }
                // The tree or one terminal fills the area, never both (D-02).
                switch nav.screen {
                case .tree:
                    WorkerTreeView(orchestratorTitle: store.rows.first { $0.id == id }?.title ?? id,
                                   session: id, project: projectFolder ?? id, log: log, now: Date(),
                                   nodeInfo: nodeInfo(session: id),
                                   result: workers.result, failure: workers.failure,
                                   holds: holds.holds, blockCover: blockCover, deadLabels: workflow.deadLabels, holdFailure: holds.failure,
                                   card: holds.card(for:), onDecide: holds.decide,
                                   retry: workers.retry,
                                   onNodeTap: { node in nav = nav.openingTerminal(of: node) },
                                   requests: requests.currentEntries, requestCard: requests.card(for:),
                                   onRequestAnswer: requests.answer,
                                   questionBinding: QuestionBinding(requests), requestStamp: requests.stamp)
                // An editor opened from a workflow tab shares this branch, so the shell keeps its identity and the tab stays mounted (D-02).
                case .workflow(let phase, let tab), .editor(_, _, .workflow(let phase, let tab)):
                    WorkflowShellView(rows: workflow.board?.rows ?? [], phase: phase, tab: tab,
                                      onPickPhase: { nav = nav.pickingPhase($0) }, onSelectTab: { nav = nav.pickingTab($0) },
                                      editor: nav.openEditor.map { AnyView(EditorView(path: $0.path, line: $0.line, project: projectFolder, rows: editorRows)) },
                                      holdBar: holdBar(root: false).map { AnyView($0) }) { tab in
                        switch tab {
                        case "context" where !workflow.contextOpen.contains(phase):
                            KitNotice(text: "Phase \(phase) has no context screen yet. It opens when the phase has context to show.").padding(Space.xxxl)
                        case "plan" where !workflow.planOpen.contains(phase):
                            KitNotice(text: "Phase \(phase) has no plan to review yet. It opens when the phase is planned.").padding(Space.xxxl)
                        case "verify" where !workflow.uatOpen.contains(phase):
                            KitNotice(text: "Phase \(phase) has no UAT to run yet. It opens when the phase reaches verify.").padding(Space.xxxl)
                        case "execute" where !workflow.executeOpen.contains(phase):
                            KitNotice(text: "Phase \(phase) has no run to follow yet. It opens when the phase starts to execute.").padding(Space.xxxl)
                        case "run" where projectFolder == nil:
                            KitNotice(text: "No project is open, so there is no run record. It opens when a project folder is set.").padding(Space.xxxl)
                        case "milestone" where (workflow.board?.status?.phases ?? []).isEmpty:
                            KitNotice(text: "This project has no phases to close yet. It opens when the roadmap has phases.").padding(Space.xxxl)
                        case "execute":
                            ExecuteScreenView(phase: phase, project: projectFolder, worktree: executeWorktree(phase),
                                              overlay: workflow.overlays[phase]?.stage == .execute ? workflow.overlays[phase] : nil,
                                              live: workflow.overlays[phase]?.stage == .execute
                                                  && workflow.overlays[phase]?.state == .running
                                                  && !workflow.endedLabels.contains(WorkflowDispatch.label(stage: .execute, phase: phase)),
                                              requests: requests, onClear: { label in Task { await workflow.clear(label) } },
                                              panel: workflow.panel, onPress: { Task { await workflow.press() } })
                        case "run":
                            RunRecordView(project: projectFolder, rows: workflow.board?.rows ?? [], message: workflow.message,
                                          chipsOff: workflow.panel?.chipsOff,
                                          onTweak: { action, proposed in Task { await workflow.pressConfigPair(action: action, proposed: proposed) } })
                        case "milestone":
                            MilestoneScreenView(project: projectFolder, milestone: workflow.board?.milestone ?? "",
                                                lastPhase: workflow.board?.status?.phases.last.flatMap { Int($0.n) }, worktree: milestoneWorktree(),
                                                workerState: workflow.milestoneState, chipsOff: workflow.panel?.chipsOff,
                                                onClose: { await workflow.closeMilestone() },
                                                onOverride: { await workflow.overrideMilestone(reason: $0) },
                                                onLand: { await workflow.landMilestone() },
                                                requests: requests,
                                                live: workflow.board?.status?.phases.last.map {
                                                    !workflow.endedLabels.contains(WorkflowDispatch.label(stage: .milestone, phase: $0.n))
                                                } ?? false,
                                                onClear: { label in Task { await workflow.clear(label) } })
                        case "context":
                            ContextScreenView(phase: phase, project: projectFolder, worktree: contextWorktree(phase),
                                              overlay: workflow.overlays[phase], requests: requests,
                                              onClear: { label in Task { await workflow.clear(label) } },
                                              panel: workflow.panel, onPress: { Task { await workflow.press() } })
                        case "plan":
                            PlanReviewView(phase: phase, project: projectFolder, worktree: planWorktree(phase),
                                           overlay: workflow.overlays[phase], planned: workflow.planOpen.contains(phase),
                                           requests: requests, onClear: { label in Task { await workflow.clear(label) } },
                                           gate: planGate, onApprove: approvePlan, rows: loadedRows,
                                           endedLabels: workflow.endedLabels)
                        case "verify":
                            UATScreenView(phase: phase, project: projectFolder, worktree: uatWorktree(phase),
                                          overlay: workflow.overlays[phase]?.stage == .verify ? workflow.overlays[phase] : nil,
                                          inbox: uatInbox(phase),
                                          live: !workflow.endedLabels.contains(WorkflowDispatch.label(stage: .verify, phase: phase)),
                                          requests: requests, onClear: { label in Task { await workflow.clear(label) } })
                        default:
                            WorkflowBoardView(board: workflow.board, failure: workflow.failure, panel: workflow.panel,
                                              message: workflow.message, overlays: workflow.overlays, held: workflow.held,
                                              onClear: { label in Task { await workflow.clear(label) } },
                                              phase: phase,
                                              executePhases: workflow.executeOpen, onOpenExecute: { nav = nav.openingWorkflow(phase: $0, tab: "execute") },
                                              holds: holds.holds,
                                              onPress: { Task { await workflow.press() } },
                                              onChip: { chip in Task { await workflow.pressChip(chip) } },
                                              onOverride: { await workflow.sendOverride(reason: $0) })
                        }
                    }
                    .id("workflow-\(phase)")
                case .terminal, .root:
                    panel(id).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .editor(let path, let line, _):
                    EditorView(path: path, line: line, project: projectFolder, rows: editorRows)
                case .shell(let folder, _):
                    if projectFolder == nil {
                        KitNotice(text: "This project has no folder, so no terminal opens.").padding(Space.xxxl)
                    } else {
                        ShellPane(folder: folder).id("shell-\(folder)-\(shellEpoch)").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if nav.showsDispatchBar(hasFolder: projectFolder != nil) {
                    DispatchPromptBar(base: id, onOpenSheet: { dispatchOpen = true }, onSent: { nav = nav.showingTree() }).id(id)
                }
            }
            .sheet(isPresented: $dispatchOpen) {
                DispatchSheet(
                    store: tasks, base: id, now: Date(),
                    onSent: { dispatchOpen = false; nav = nav.showingTree() },
                    onClose: { dispatchOpen = false })
            }
            .environment(\.openInEditor, { url, line in nav = nav.openingEditor(path: url.path, line: line) })
        } else {
            EmptyStateView()
        }
    }

    private func dispatchBar(_ id: String) -> some View {
        // The same inputs as the tree view, so the counts agree with the card colours (hold and block-cover rules).
        let treeCounts = WorkerTree(orchestratorTitle: store.rows.first { $0.id == id }?.title ?? id, result: workers.result,
                                    log: log, now: Date(), holds: holds.holds, cover: blockCover, deadLabels: workflow.deadLabels).counts
        let counts = nav.bandCounts(waiting: treeCounts.waiting, running: treeCounts.running)
        return DispatchBar(
            showsBack: nav.canGoBack, showsActions: projectFolder != nil, waiting: counts.waiting, running: counts.running,
            sessionName: nav.terminalLabel == nil ? nil : target, showsWaitingCue: nav.showsWaitingCue,
            onBack: { nav = nav.goingBack() },
            showsTerminal: nav.screen == .tree && projectFolder != nil,
            onTerminal: { if let folder = projectFolder { nav = nav.openingShell(folder: folder) } },
            showsWorkflow: nav.screen == .tree && projectFolder != nil,
            onWorkflow: {
                let rows = workflow.board?.rows ?? []
                nav = nav.openingWorkflow(phase: WorkflowTabs.defaultPhase(status: workflow.board?.status, rows: rows) ?? "", tab: "board")
            },
            showsClear: { if case .shell = nav.screen { true } else { false } }(),
            onClear: { if let folder = projectFolder { ShellStore.shared.close(folder); shellEpoch += 1 } },
            onClose: { if let id = selection, let row = store.rows.first(where: { $0.id == id }) { closer.ask(row, in: store.snapshot) } })
    }

    private func panel(_ id: String) -> some View {
        SessionScreen(
            target: target,
            actionsStrip: selectedWorker != nil ? selectedRow.map { actionsStrip($0, base: id) } : nil,
            markDoneText: markDoneText, holdBar: holdBar(root: isRoot(id)),
            // The host keys its live view by out-log path, so each node gets a fresh conversation view.
            conversation: ConversationHost(path: outLogPath(), inboxPath: inboxPath(), ended: gone(id),
                                           nodeKey: selectedWorker ?? WorkerTree.orchestratorKey, requests: requests,
                                           resume: ResumeTarget.choose(root: isRoot(id), worker: selectedWorker, folder: projectFolder)))
    }

    /// The selected node's inbox: the worker row's path or the dashboard's. Nil disables the prompt box.
    private func inboxPath() -> String? {
        if let id = selection, isRoot(id) { return WorkerState.rootDashboardPaths().inbox }
        guard case .loaded(let state) = workers.result else { return nil }
        guard let worker = selectedWorker else { return state.dashboardInboxPath }
        return state.rows.first { $0.agentId == worker }?.inboxPath
    }

    /// The selected node's out log: the worker row's path (looked up directly, so a finished worker keeps it) or the dashboard's.
    private func outLogPath() -> String? {
        if let id = selection, isRoot(id) { return WorkerState.rootDashboardPaths().out }
        guard case .loaded(let state) = workers.result else { return nil }
        guard let worker = selectedWorker else { return state.dashboardOutPath }
        return state.rows.first { $0.agentId == worker }?.outPath
    }

    /// Every hold and request of the project, with the closures the tree gets. Nil when nothing is pending. A root session gets requests only, no gate holds.
    private func holdBar(root: Bool) -> ProjectHoldBarView? {
        ProjectHoldBar(holds: holds.holds, requests: requests.currentEntries, root: root).map {
            ProjectHoldBarView(bar: $0, card: holds.card(for:), onDecide: holds.decide,
                               requestCard: requests.card(for:),
                               onRequestAnswer: requests.answer, questionBinding: QuestionBinding(requests),
                               requestStamp: requests.stamp, onRequestEscape: { requests.interrupt(nodeKey: $0) })
        }
    }

    /// The out-log path of each node of the selected project, by node key (`dashboard` and each worker's `agentId`).
    private var logPaths: [String: String] {
        guard let id = selection else { return [:] }
        if isRoot(id) { return [WorkerTree.orchestratorKey: WorkerState.rootDashboardPaths().out] }
        guard case .loaded(let state) = workers.result else { return [:] }
        var paths: [String: String] = [:]
        if let out = state.dashboardOutPath { paths[WorkerTree.orchestratorKey] = out }
        for row in state.rows { if let out = row.outPath { paths[row.agentId] = out } }
        return paths
    }

    /// Each node's log status by node key, from the followed paths.
    private var log: [String: SessionStatusStore.Entry] {
        logPaths.compactMapValues { logStatus.entries[$0] }
    }

    /// Feeds the request store the project's sessions: the dashboard and every worker row with an out log and an inbox.
    /// Runs on each log publish and each 2 s tick, so a window ends at its reset time (D-10: no new timer).
    private func updateUsage() {
        let updated = UsageLimits.update(usage, entries: logStatus.entries, now: Date())
        if updated != usage { usage = updated }
    }

    /// The selected project's logs plus those of every open project, so the usage panel sees the newest limits (D-15).
    private func followLogs() {
        logStatus.follow(Set(logPaths.values).union(openLogs.paths))
    }

    private func syncRequests() {
        followLogs()
        let root = selection.map(isRoot) ?? false
        var state: WorkerState?
        if case .loaded(let loaded) = workers.result { state = loaded }
        requests.setSessions(RequestSessions.all(
            hasSelection: selection != nil, isRoot: root, state: state,
            live: { row in selection.map { SessionListing.workerTerminalEnabled(label: row.agentId, status: row.status, windows: store.snapshot.windows, session: $0) } ?? false },
            states: openLogs.states, folder: projectFolder))
    }

    private func actionsStrip(_ row: WorkerRow, base id: String) -> WorkerActionsView {
        let verdict = uatGate.effective(granted: overrideStore.granted)
        let eligibility = UATOverride.eligibility(verdict: verdict, row: row, liveness: overrideLiveness(row))
        let actions = WorkerActions(row: row, pullRequest: pullRequests.state, uat: verdict, override: eligibility,
                                    ended: workflow.deadLabels.contains(row.agentId))
        var strip = WorkerActionsView(
            actions: actions, onMerge: { pressMerge(row, base: id, kind: actions.mergeKind) },
            onTeardown: { startTeardown(row) }, onMarkDone: { pressMarkDone(row) },
            onClear: { Task { await workflow.clear(row.agentId) } },
            pullRequest: heldPullRequest, requestText: requestText,
            onMergeAnyway: { gatedPress { startMerge(row, base: id, unknownPullRequestAllowed: true) } },
            onRefresh: { pullRequests.refresh() })
        strip.overrideState = overrideStore.label == row.agentId ? overrideStore.state : .idle
        strip.onOverride = { reason in
            guard let phase = UATGate.phase(ofLabel: row.agentId) else { return }
            overrideStore.send(reason: reason, row: row, eligibility: eligibility, phase: phase)
        }
        strip.onOverrideCancel = { overrideStore.cancel() }
        return strip
    }

    /// A worker whose window tmux reports gone is not live. Until tmux answers, `endedLabels` is empty and the worker counts as live.
    private func overrideLiveness(_ row: WorkerRow) -> UATOverride.Liveness {
        .live(workflow.endedLabels.contains(row.agentId) ? [] : [row.agentId])
    }

    /// Feeds the override store the rows and the live set, and opens merge-review on a grant for the local route only.
    private func syncOverride() {
        guard case .loaded(let state) = workers.result else { return }
        overrideStore.rowsChanged(state.rows, live: Set(state.rows.map(\.agentId)).subtracting(workflow.endedLabels))
    }

    private func overrideGranted(_ label: String) {
        guard let row = selectedRow, row.agentId == label, let id = selection else { return }
        if case .loaded(let held?) = pullRequests.state, held.isOpen { return }
        startMerge(row, base: id)
    }
}

