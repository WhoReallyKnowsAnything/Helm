import Foundation

/// What the board shows for one project.
struct WorkflowBoard: Equatable {
    struct Row: Equatable {
        var n: String
        var name: String
        var display: WorkflowStageMap.Display
    }

    var milestone: String
    var rows: [Row]
    /// Inputs for the gates and the next stage (tasks 7 and 8).
    var status: CadenceStatus?
    var config: CadenceConfig?
    /// The milestone-wide broken count, or the reason the audit failed (G4 is blocked then).
    var audit: Result<Int, CadenceLocator.Failure>?
    /// The next legal stage, and the stage after it with its gate verdict (D-05, D-06).
    var next: WorkflowGates.Next?
    var skipAhead: SkipAhead?
    /// The health strip. Nil only in tests that build a bare board.
    var health: CadenceHealth?
    /// The config check (CONFIG-01). A failure holds its reason and leaves the rest of the board alone.
    var configCheck: Result<CadenceConfigCheck, CadenceLocator.Failure>?
    /// The suggested-skill chips, and why the suggest read failed (that reason replaces only the suggest chip).
    var chips: [CadenceChip] = []
    var suggestReason: String?

    struct SkipAhead: Equatable {
        var stage: WorkflowGates.Stage
        var verdict: WorkflowGates.Verdict
    }
}

extension WorkflowBoard {
    /// `status` and `config` are the inputs; `hasContext` is for the first phase that is not complete.
    static func derive(status: CadenceStatus, config: CadenceConfig, hasContext: Bool,
                       audit: Result<Int, CadenceLocator.Failure>?) -> (WorkflowGates.Next, SkipAhead?) {
        let next = WorkflowGates.nextStage(status: status, hasContext: hasContext, skipDiscuss: config.skipDiscuss)
        guard let after = next.stage?.following else { return (next, nil) }
        let verdict = WorkflowGates.verdict(for: after, status: status, hasContext: hasContext,
                                            skipDiscuss: config.skipDiscuss, audit: audit)
        return (next, SkipAhead(stage: after, verdict: verdict))
    }
}

/// One refresh for a project folder. Runs on the store's private queue, never on the main actor.
typealias WorkflowSource = @Sendable (String) -> Result<WorkflowBoard, CadenceLocator.Failure>

/// The selected project's workflow board. Modelled on `WorkerStore`: no timer, a generation counter drops results
/// of a replaced project, and a request during a refresh causes exactly one more refresh.
@MainActor
final class WorkflowStore: ObservableObject {
    @Published private(set) var board: WorkflowBoard?
    @Published private(set) var failure: String?
    /// The button, routing text and override as one value, rebuilt on each refresh. A press reads this, not the settings.
    @Published private(set) var panel: WorkflowPanel?
    /// The milestone close target, built with the panel: the last phase and the milestone routing. A press reads this, never the settings.
    @Published private(set) var milestoneTarget: WorkflowPanel.Target?
    /// The state of the held `cad-milestone-p<last>` worker, or nil.
    @Published private(set) var milestoneState: WorkflowOverlay.State?
    /// Why the last press or override sent nothing, or nil.
    @Published private(set) var message: String?
    /// The running overlay per phase text, from the worker rows and the live tmux windows.
    @Published private(set) var overlays: [String: WorkflowOverlay] = [:]
    /// The phases whose board row offers Open for the context screen (D-06).
    @Published private(set) var contextOpen: Set<String> = []
    /// The phases whose board row offers Open for the plan review screen (D-08).
    @Published private(set) var planOpen: Set<String> = []
    /// The phases whose board row offers Open for the UAT screen: verify stage or a held verify worker.
    @Published private(set) var uatOpen: Set<String> = []
    /// The phases whose board row offers Open for the execute screen: a phase with plans or a held execute worker (UD-1).
    @Published private(set) var executeOpen: Set<String> = []
    /// Rows whose worker has no live window and is past the starting window, from all rows (the tree shows them as dead).
    @Published private(set) var deadLabels: Set<String> = []
    /// Rows of any state whose window tmux reports gone. Empty until tmux answers, so an unanswered poll counts as live.
    @Published private(set) var endedLabels: Set<String> = []
    private var pendingQuestions: Set<String> = []
    /// The label a refused press found already held, for the Clear offer.
    @Published private(set) var held: String?

    private let labels: WorkflowLabels
    private let kill: WorkflowKill
    private let now: () -> Date
    private var rows: [WorkerRow] = []
    private var liveResult: Result<Set<String>, SessionCheckFailure>?
    private var clearing = false
    private let source: WorkflowSource
    private let liveness: WorkflowLiveness
    private let routing: StageRouting
    private let makeDeliver: (String) -> @Sendable (String) -> InboxDelivery.Outcome
    /// Does this plan worker's worktree hold plan files? Runs off the main actor.
    private let planFiles: PlanFilesCheck
    private var planReadyLabels: Set<String> = []
    private var planGeneration = 0
    private let planQueue = DispatchQueue(label: "WorkflowStore.planFiles")
    private var model: DispatchModel?
    /// Labels whose line was sent but whose worker row or window has not shown yet, with the send time.
    /// A second send of the same label is refused until the row or window shows, or `pendingTimeout` passes.
    private var pending: [String: Date] = [:]
    static let pendingTimeout: TimeInterval = 60
    private var live = WorkflowLive.checking
    private let queue = DispatchQueue(label: "WorkflowStore.refresh")
    private var project: String?
    private var base: String?
    /// Turns each change under `.planning/` into a refresh request. Released on re-point, which stops the stream.
    private var watcher: ProjectWatcher?
    private var generation = 0
    private var refreshing = false
    private var refreshAgain = false

    init(source: @escaping WorkflowSource = WorkflowStore.liveSource,
         liveness: @escaping WorkflowLiveness = WorkflowStore.liveLiveness,
         routing: StageRouting = StageRouting(defaults: .standard),
         makeDeliver: @escaping (String) -> @Sendable (String) -> InboxDelivery.Outcome = { base in { InboxDelivery.deliver($0, base: base) } },
         labels: @escaping WorkflowLabels = WorkflowStore.liveLabels,
         kill: @escaping WorkflowKill = WorkflowStore.liveKill,
         planFiles: @escaping PlanFilesCheck = WorkflowStore.livePlanFiles,
         now: @escaping () -> Date = Date.init) {
        self.planFiles = planFiles
        self.labels = labels
        self.kill = kill
        self.now = now
        self.source = source
        self.liveness = liveness
        self.routing = routing
        self.makeDeliver = makeDeliver
    }

    /// `base` is the project's tmux session, the target of every press.
    func point(at folder: String?, base: String? = nil) {
        guard folder != project || base != self.base else { return }
        self.base = base
        model = base.map { DispatchModel(deliver: makeDeliver($0)) }
        live = .checking
        panel = nil
        message = nil
        rows = []
        liveResult = nil
        if !overlays.isEmpty { overlays = [:] }
        if !deadLabels.isEmpty { deadLabels = [] }
        if !endedLabels.isEmpty { endedLabels = [] }
        planReadyLabels = []
        planGeneration += 1
        held = nil
        pending = [:]
        generation += 1
        refreshing = false
        refreshAgain = false
        project = folder
        watcher = folder.map { ProjectWatcher(planningOf: $0) { [weak self] in Task { @MainActor in self?.requestRefresh() } } }
        if board != nil { board = nil }
        if failure != nil { failure = nil }
        requestRefresh()
    }

    func requestRefresh() {
        guard let project else { return }
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        let current = generation
        let source = source, liveness = liveness, base = base
        queue.async { [weak self] in
            let outcome = source(project)
            let off = liveness(base)
            Task { @MainActor in self?.finish(outcome, off: off, generation: current) }
        }
    }

    /// Checks the orchestrator window again with no status run (D-10). Called when the window list changes.
    func recheckLive() {
        guard project != nil else { return }
        let current = generation, liveness = liveness, base = base
        queue.async { [weak self] in
            let off = liveness(base)
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.live = off.map(WorkflowLive.off) ?? .live
                self.rebuildPanel()
            }
        }
    }

    /// The loaded worker rows. Recomputes the overlay; a held label that is no longer held drops its Clear offer.
    func setRows(_ new: [WorkerRow]) {
        guard new != rows else { return }
        rows = new
        if let label = held, heldRow(label) == nil { held = nil }
        pending = pending.filter { heldRow($0.key) == nil }
        recomputeOverlays()
        recheckPlanFiles()
    }

    /// One plan-list call per finished plan worker, per worker-row change. A stale answer is dropped by generation.
    private func recheckPlanFiles() {
        guard let project else { return }
        let current = now()
        let targets = rows.compactMap { row -> (label: String, worktree: String, phase: String)? in
            guard let worktree = row.worktreePath, WorkerStatusRules.status(of: row, lastWrite: nil, now: current) == .finished,
                  let m = row.agentId.range(of: #"^cad-plan-p([0-9]+(\.[0-9]+)?)$"#, options: .regularExpression)
            else { return nil }
            return (row.agentId, worktree, String(row.agentId[m].dropFirst("cad-plan-p".count)))
        }
        planGeneration += 1
        let generation = planGeneration, check = planFiles
        planQueue.async { [weak self] in
            let ready = Set(targets.filter { check(project, $0.worktree, $0.phase) }.map(\.label))
            Task { @MainActor in
                guard let self, generation == self.planGeneration, ready != self.planReadyLabels else { return }
                self.planReadyLabels = ready
                self.applyOverlays()
            }
        }
    }

    typealias PlanFilesCheck = @Sendable (_ project: String, _ worktree: String, _ phase: String) -> Bool

    nonisolated static let livePlanFiles: PlanFilesCheck = { project, worktree, phase in
        let loader = PlanReviewLoader()
        let (root, kind) = loader.chooseRoot(project: project, worktree: worktree)
        return kind == .worktree && !loader.planWaves(root: root, phase: phase).isEmpty
    }

    /// Labels with a live pending AskUserQuestion. Only a running overlay of a screen-stage label shows it (D-02).
    func setPendingQuestions(_ labels: Set<String>) {
        guard labels != pendingQuestions else { return }
        pendingQuestions = labels
        applyOverlays()
    }

    /// Asks tmux which stage-worker windows are alive, off the main actor, with no status run and no timer.
    func recomputeOverlays() {
        guard project != nil else { return }
        let current = generation, labels = labels, base = base
        queue.async { [weak self] in
            let result = labels(base)
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.liveResult = result
                self.applyOverlays()
            }
        }
    }

    private func hasPlans(_ phase: String) -> Bool {
        project.map { WorkflowStageMap.hasPlans(project: $0, phase: phase) } ?? false
    }

    private func applyOverlays() {
        var next: [String: WorkflowOverlay] = [:]
        var open: Set<String> = []
        var planned: Set<String> = []
        var uat: Set<String> = []
        var execute: Set<String> = []
        var dead: Set<String> = []
        var ended: Set<String> = []
        var assumed: Set<String>?
        var milestone: WorkflowOverlay.State?
        switch liveResult {
        case .success(let live)?:
            assumed = live
            pending = pending.filter { !live.contains($0.key) }
            ended = Set(rows.map(\.agentId)).subtracting(live)
            dead = Set(rows.filter { WorkflowOverlay.state(of: $0, live: live.contains($0.agentId), now: now()) == .dead }.map(\.agentId))
        // Tmux has not answered yet: a held row still gates, so assume every row is live.
        case nil: assumed = Set(rows.map(\.agentId))
        case .failure?: break
        }
        if deadLabels != dead { deadLabels = dead }
        if endedLabels != ended { endedLabels = ended }
        if let live = assumed, let board {
            milestone = board.status?.phases.last.flatMap {
                WorkflowOverlay.heldState(label: WorkflowDispatch.label(stage: .milestone, phase: $0.n), rows: rows, liveLabels: live, now: now())
            }
            for row in board.rows {
                if var overlay = WorkflowOverlay.derive(phase: row.n, rows: rows, liveLabels: live, now: now()) {
                    overlay.questionWaiting = pendingQuestions.contains(overlay.label)
                        && ContextCardState.state(label: overlay.label, overlay: overlay.state, live: true) == .answerable
                    overlay.planReady = overlay.stage == .plan && planReadyLabels.contains(overlay.label)
                    next[row.n] = overlay
                }
                let label = WorkflowDispatch.label(stage: .context, phase: row.n)
                let held = WorkflowOverlay.heldState(label: label, rows: rows, liveLabels: live, now: now())
                if ContextCardState.offersOpen(display: row.display, contextState: held) { open.insert(row.n) }
                let planLabel = WorkflowDispatch.label(stage: .plan, phase: row.n)
                let planHeld = WorkflowOverlay.heldState(label: planLabel, rows: rows, liveLabels: live, now: now())
                if row.display == .stage(.planned) || planHeld != nil { planned.insert(row.n) }
                let verifyLabel = WorkflowDispatch.label(stage: .verify, phase: row.n)
                let verifyHeld = WorkflowOverlay.heldState(label: verifyLabel, rows: rows, liveLabels: live, now: now())
                if ContextCardState.offersOpenUAT(display: row.display, verifyState: verifyHeld) { uat.insert(row.n) }
                let executeLabel = WorkflowDispatch.label(stage: .execute, phase: row.n)
                let executeHeld = WorkflowOverlay.heldState(label: executeLabel, rows: rows, liveLabels: live, now: now())
                if ContextCardState.offersOpenExecute(hasPlans: hasPlans(row.n), executeState: executeHeld) { execute.insert(row.n) }
            }
        } else if let board {
            for row in board.rows where ContextCardState.offersOpen(display: row.display, contextState: nil) { open.insert(row.n) }
            for row in board.rows where row.display == .stage(.planned) { planned.insert(row.n) }
            for row in board.rows where ContextCardState.offersOpenUAT(display: row.display, verifyState: nil) { uat.insert(row.n) }
            for row in board.rows where ContextCardState.offersOpenExecute(hasPlans: hasPlans(row.n), executeState: nil) { execute.insert(row.n) }
        }
        if contextOpen != open { contextOpen = open }
        if planOpen != planned { planOpen = planned }
        if uatOpen != uat { uatOpen = uat }
        if executeOpen != execute { executeOpen = execute }
        if overlays != next { overlays = next }
        if milestoneState != milestone { milestoneState = milestone }
        rebuildPanel()
    }

    private func rebuildPanel() {
        var liveError: String?
        if case .failure(let failure)? = liveResult { liveError = failure.reason }
        let overlay = board?.next?.phase.flatMap { overlays[$0] }
        var next = board.map { WorkflowPanel.make(board: $0, live: live, routing: routing, overlay: overlay, liveError: liveError) }
        next?.utility = routing.utilityEntry()
        // A sent line not yet matched by a worker row or window keeps Next off. Other off reasons stay as they are.
        if let target = next?.next, case .enabled? = next?.button,
           isPending(WorkflowDispatch.label(stage: target.stage, phase: target.phase)) {
            next?.button = .off(Self.sentLine(WorkflowDispatch.label(stage: target.stage, phase: target.phase)))
        }
        if case .success(let liveLabels)? = liveResult {
            next?.configHold = WorkflowOverlay.heldState(label: Self.configLabel, rows: rows, liveLabels: liveLabels, now: now())
        } else if heldRow(Self.configLabel) != nil {
            next?.configHold = .running
        }
        if let liveError { next?.chipsOff = liveError }
        else if case .off(let why) = live { next?.chipsOff = why }
        else if case .checking = live { next?.chipsOff = "Checking for the orchestrator window." }
        if panel != next { panel = next }
        let target = board?.status?.phases.last.map { WorkflowPanel.Target(stage: .milestone, phase: $0.n, routing: routing.entry(for: .milestone)) }
        if milestoneTarget != target { milestoneTarget = target }
    }

    static let configLabel = WorkflowDispatch.label(skill: "/cadence:cad-config", phase: nil)

    private func heldRow(_ label: String) -> WorkerRow? {
        rows.first { $0.agentId == label && $0.status != "merged" && $0.status != "dead" }
    }

    /// Stops a stage worker with `dispatch-task.sh --kill`, one run at a time. The branch stays as an orphaned session branch.
    func clear(_ label: String) async {
        guard !clearing, let project else { return }
        clearing = true
        defer { clearing = false }
        let kill = kill
        let run = await Task.detached { kill(label, project) }.value
        if run.failure == nil, run.status == 0 {
            message = nil
            recomputeOverlays()
        } else {
            let output = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
            message = "Clear failed for \(label): " + (output.isEmpty ? run.failure.map { "\($0)" } ?? "exit \(run.status)" : output)
        }
    }

    /// The next-step button. Sends the line the board showed, built from `panel`, never from the settings.
    func press() async {
        guard let panel, case .enabled = panel.button, let target = panel.next else { return }
        _ = await send(target, reason: nil)
    }

    /// The override of a blocked gate. True when the line was sent. Empty or over-long reasons are refused.
    func sendOverride(reason: String) async -> Bool {
        guard let target = panel?.override else { return false }
        return await send(target, reason: reason)
    }

    /// The milestone Close with no reason. True when the line was sent. The held-label refusal stays in `deliver`.
    func closeMilestone() async -> Bool {
        guard let target = milestoneTarget else { return false }
        return await send(target, reason: nil)
    }

    /// The milestone Close over a failing audit. A blank reason is refused and nothing is sent.
    func overrideMilestone(reason: String) async -> Bool {
        guard let target = milestoneTarget else { return false }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = WorkflowDispatch.Refusal.emptyReason.message
            return false
        }
        return await send(target, reason: reason)
    }

    /// Land after the close. cad-land runs inside the milestone worker, so the line uses the milestone routing. It is
    /// refused here, with nothing sent, when that worker is not live. The `cad-land-p<N>` label never matches a held row.
    func landMilestone() async -> Bool {
        guard let target = milestoneTarget else { return false }
        guard let state = milestoneState, state != .dead else {
            message = "No live \(WorkflowDispatch.label(stage: .milestone, phase: target.phase)) worker to land with. Nothing was sent."
            return false
        }
        return await deliver(label: WorkflowDispatch.label(skill: "/cadence:cad-land", phase: target.phase),
                             WorkflowDispatch.line(skill: "/cadence:cad-land", phase: target.phase, routing: target.routing))
    }

    /// A chip press. The line comes from the displayed chip and the displayed utility entry, never from the settings.
    func pressChip(_ chip: CadenceChip) async {
        guard let panel else { return }
        if let why = panel.chipsOff { message = why; return }
        _ = await deliver(label: chip.label, WorkflowDispatch.chipLine(
            skill: chip.skill, phase: chip.phase, argument: chip.argument, routing: panel.utility))
    }

    /// A priced run-record tweak. Same gates as a chip press: the chips-off reason, the utility routing, the held-label check.
    func pressConfigPair(action: String, proposed: String) async {
        guard let panel else { return }
        if let why = panel.chipsOff { message = why; return }
        _ = await deliver(label: WorkflowDispatch.label(skill: "/cadence:cad-config", phase: nil),
                          WorkflowDispatch.suggestionConfigLine(action: action, proposed: proposed, routing: panel.utility))
    }

    private func send(_ target: WorkflowPanel.Target, reason: String?) async -> Bool {
        await deliver(label: WorkflowDispatch.label(stage: target.stage, phase: target.phase),
                      WorkflowDispatch.line(stage: target.stage, phase: target.phase, routing: target.routing, reason: reason))
    }

    private func isPending(_ label: String) -> Bool {
        pending[label].map { now().timeIntervalSince($0) < Self.pendingTimeout } ?? false
    }

    private static func sentLine(_ label: String) -> String { "Sent the line for \(label). Waiting for the worker." }

    private func deliver(label: String, _ built: Result<String, WorkflowDispatch.Refusal>) async -> Bool {
        guard let model else { message = "No project session to send to."; return false }
        // A stale view must never start a second worker: the rows decide, not the overlay.
        if let row = heldRow(label) {
            held = label
            message = "\(label) is already held (\(row.status)). Nothing was sent. Clear the old worker first."
            return false
        }
        switch built {
        case .failure(let refusal):
            message = refusal.message
            return false
        case .success(let line):
            if isPending(label) {
                message = "The line for \(label) was already sent. Nothing more was sent."
                return false
            }
            await model.sendLine(line)
            if model.sent {
                pending[label] = now()
                message = Self.sentLine(label)
                rebuildPanel()
                // The button returns at the timeout with no other event.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.pendingTimeout + 1))
                    self?.rebuildPanel()
                }
            } else {
                message = model.message
            }
            return model.sent
        }
    }

    private func finish(_ outcome: Result<WorkflowBoard, CadenceLocator.Failure>, off: String?, generation done: Int) {
        guard done == generation else { return }
        refreshing = false
        live = off.map(WorkflowLive.off) ?? .live
        defer { applyOverlays() }
        switch outcome {
        case .success(let next):
            if board != next { board = next }
            if failure != nil { failure = nil }
        case .failure(let problem):
            // On any failure the board shows the reason and nothing else.
            if board != nil { board = nil }
            if failure != problem.reason { failure = problem.reason }
        }
        if refreshAgain {
            refreshAgain = false
            requestRefresh()
        }
    }

    /// The live stage-worker windows of the base session, or the reason tmux could not be asked.
    nonisolated static let liveLabels: WorkflowLabels = { base in
        guard let base else { return .failure(.init(reason: "No project session to ask about workers.")) }
        return WorkerLiveness.liveLabels(base: base)
    }

    nonisolated static let liveKill: WorkflowKill = { label, folder in
        do {
            return MergeReview.kill(label: label, folder: folder, environment: try MergeReview.environment())
        } catch {
            return MergeReview.Run(output: "", status: -1, failure: .didNotStart(error.localizedDescription))
        }
    }

    /// A dashboard window must be live in the base session. Nil means yes, else the reason the button is off.
    nonisolated static let liveLiveness: WorkflowLiveness = { base in
        guard let base else { return "No orchestrator window to send to." }
        do {
            guard let windows = try ProjectSession.liveWindows(base: base), windows.contains(where: { $0.name == "dashboard" }) else {
                return "No orchestrator window to send to for \(base)."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Locator, status, CONTEXT.md presence and ROADMAP.md, in that order.
    static let liveSource: WorkflowSource = { project in
        guard FileManager.default.fileExists(atPath: project + "/.planning") else {
            return .failure(.init(reason: "This project has no .planning folder, so it has no Cadence workflow."))
        }
        let scripts: CadenceLocator.Scripts
        switch CadenceLocator.locate() {
        case .failure(let problem): return .failure(problem)
        case .success(let found): scripts = found
        }
        let status: CadenceStatus
        switch CadenceStatus.run(scripts, project: project) {
        case .failure(let problem): return .failure(problem)
        case .success(let found): status = found
        }
        let config: CadenceConfig
        switch CadenceConfig.run(scripts, project: project) {
        case .failure(let problem): return .failure(problem)
        case .success(let found): config = found
        }
        // One audit run feeds G4 (the fail count) and the health cell (the counts).
        let milestoneAudit = MilestoneAudit.run(scripts, project: project)
        let auditCounts = milestoneAudit.map(\.counts)
        let audit = milestoneAudit.map(\.failCount)
        let roadmap = try? String(contentsOfFile: project + "/.planning/ROADMAP.md", encoding: .utf8)
        let rows = status.phases.map { phase in
            WorkflowBoard.Row(
                n: phase.n, name: phase.name,
                display: WorkflowStageMap.display(
                    status: phase.status, hasContext: WorkflowStageMap.hasContext(project: project, phase: phase.n),
                    skipDiscuss: config.skipDiscuss))
        }
        let open = status.phases.first { $0.status != "complete" }
        let openHasContext = open.map { WorkflowStageMap.hasContext(project: project, phase: $0.n) } ?? false
        let (next, skipAhead) = WorkflowBoard.derive(status: status, config: config, hasContext: openHasContext, audit: audit)
        let configCheck = CadenceConfigCheck.run(scripts, project: project)
        var suggest: [CadenceSuggest.Entry] = []
        var suggestReason: String?
        switch CadenceSuggest.run(scripts, project: project) {
        case .success(let found): suggest = found
        case .failure(let problem): suggestReason = problem.reason
        }
        let decisions = CadenceChips.decisionCounts(project: project, rows: rows)
        var reviewer: (model: String, effort: String)?
        if case .success(let found) = configCheck { reviewer = (found.reviewerModel, found.reviewerEffort) }
        let health = CadenceHealth(status: status, audit: auditCounts, debug: CadenceHealth.openDebugFiles(project: project),
                                   capture: CadenceHealth.openCaptureTodos(scripts, project: project))
        return .success(WorkflowBoard(
            milestone: WorkflowStageMap.milestoneName(roadmap: roadmap, status: status), rows: rows,
            status: status, config: config, audit: audit, next: next, skipAhead: skipAhead,
            health: health, configCheck: configCheck,
            chips: CadenceChips.make(rows: rows, next: next, drift: status.drift, suggest: suggest, decisions: decisions,
                                     reviewerModel: reviewer?.model, reviewerEffort: reviewer?.effort),
            suggestReason: suggestReason))
    }
}


/// Whether the project's orchestrator window is there to receive a line. Checked on each refresh (D-10).
enum WorkflowLive: Equatable {
    case checking, live
    case off(String)
}

/// Asks tmux about one base session, off the main actor. Nil means a dashboard window exists; else the reason.
typealias WorkflowLiveness = @Sendable (_ base: String?) -> String?

/// The fix chips of the displayed config check. A fix is a chip press: the line comes from the chip table, so the
/// app writes no config and builds no second line shape.
extension CadenceConfigCheck {
    private func chip(_ rows: [Row]) -> CadenceChip {
        CadenceChip(skill: "/cadence:cad-config", phase: nil,
                    argument: rows.map { "\($0.key)=\($0.recommended.text)" }.joined(separator: " "),
                    rule: "config check: " + rows.map(\.key).joined(separator: ", "))
    }

    /// The fix for one flagged key, nil for a key that is not flagged.
    func fixChip(key: String) -> CadenceChip? {
        rows.first { $0.key == key && $0.differs }.map { chip([$0]) }
    }

    /// One chip holding every flagged pair in table order, nil unless 2 or more are flagged.
    func fixAllChip() -> CadenceChip? {
        let flagged = rows.filter(\.differs)
        return flagged.count >= 2 ? chip(flagged) : nil
    }
}

/// The live stage-worker window names of one base session, or why tmux could not be asked.
typealias WorkflowLabels = @Sendable (_ base: String?) -> Result<Set<String>, SessionCheckFailure>

/// Runs the `--kill` for one label in one project folder.
typealias WorkflowKill = @Sendable (_ label: String, _ folder: String) -> MergeReview.Run

/// What the board shows beside the next-step button, as one value. A press reads this value, never the settings.
struct WorkflowPanel: Equatable {
    struct Target: Equatable {
        var stage: WorkflowGates.Stage
        var phase: String
        var routing: StageRouting.Entry

        var routingText: String {
            if routing.model == nil, routing.effort == nil { return "default model" }
            return "\(routing.model ?? "default model") / \(routing.effort ?? "default effort")"
        }
    }

    struct RoleRow: Equatable {
        var name: String
        var text: String
    }

    enum Button: Equatable {
        case enabled
        case off(String)
    }

    var next: Target?
    var button: Button
    var roles: [RoleRow]
    /// The stage a blocked gate offers to override, and the gate's reason.
    var override: Target?
    var overrideReason: String?
    /// The phase's running, waiting or dead stage worker. While it exists the button and the override are off.
    var overlay: WorkflowOverlay?
    /// The utility session every chip uses, as read when the panel was built. A chip press reads this, not the settings.
    var utility = StageRouting.utilityFallback
    /// Why every chip is off (no live orchestrator window), or nil.
    var chipsOff: String?
    /// The state of a held `cad-config` worker, or nil. While set, the config fix buttons are off.
    var configHold: WorkflowOverlay.State?

    var utilityText: String {
        "utility: \(utility.model ?? "default model")" + (utility.effort.map { " / \($0)" } ?? "")
    }

    /// D-13: the Cadence roles of each stage. Milestone has none.
    static let roleNames: [WorkflowGates.Stage: [String]] = [
        .context: ["cad-assumptions-analyzer"], .plan: ["cad-planner", "cad-plan-checker"],
        .execute: ["cad-executor"], .verify: ["cad-verifier"], .milestone: [],
    ]

    static func make(board: WorkflowBoard, live: WorkflowLive, routing: StageRouting,
                     overlay: WorkflowOverlay? = nil, liveError: String? = nil) -> WorkflowPanel {
        guard let next = board.next, let stage = next.stage, let phase = next.phase else {
            return WorkflowPanel(next: nil, button: .off(board.next?.reason ?? "There is no next stage."), roles: [])
        }
        let target = Target(stage: stage, phase: phase, routing: routing.entry(for: stage))
        let roles = (roleNames[stage] ?? []).map { name -> RoleRow in
            let role = board.config?.roles[name]
            return RoleRow(name: name, text: role.map { "\($0.model) / \($0.effort)" } ?? "unknown")
        }
        if let overlay { return WorkflowPanel(next: target, button: .off(overlay.text), roles: roles, overlay: overlay) }
        if let liveError { return WorkflowPanel(next: target, button: .off(liveError), roles: roles) }
        // The next stage is allowed or blocked on its own. `hasContext` only matters for plan, which is next only when allowed.
        var verdict = WorkflowGates.Verdict.allowed
        if let status = board.status, let config = board.config {
            verdict = WorkflowGates.verdict(for: stage, status: status, hasContext: true, skipDiscuss: config.skipDiscuss, audit: board.audit)
        }
        var override: Target?
        var overrideReason: String?
        if case .blocked(let why) = verdict {
            override = target
            overrideReason = why
        } else if let ahead = board.skipAhead, case .blocked(let why) = ahead.verdict {
            override = Target(stage: ahead.stage, phase: phase, routing: routing.entry(for: ahead.stage))
            overrideReason = why
        }
        let button: Button
        if case .blocked(let why) = verdict {
            button = .off(why)
        } else {
            switch live {
            case .live: button = .enabled
            case .checking: button = .off("Checking for the orchestrator window.")
            case .off(let why): button = .off(why)
            }
        }
        return WorkflowPanel(next: target, button: button, roles: roles, override: override, overrideReason: overrideReason)
    }
}
