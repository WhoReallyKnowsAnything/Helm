import Foundation
import Combine
import Testing
@testable import Helm

/// Counts source calls and holds the first one open until released.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    let release = DispatchSemaphore(value: 0)
    var holdFirst = false
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func enter() -> Int { lock.lock(); defer { lock.unlock() }; _calls += 1; return _calls }
}

@MainActor @Suite struct WorkflowStoreTests {
    private func board(_ milestone: String) -> WorkflowBoard {
        WorkflowBoard(milestone: milestone, rows: [.init(n: "1", name: "a", display: .stage(.planned))])
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<300 where !until() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func refreshPublishesAndNilClears() async {
        let store = WorkflowStore(source: { _ in .success(WorkflowBoard(milestone: "m", rows: [])) })
        store.point(at: "/p")
        await settle { store.board != nil }
        #expect(store.board?.milestone == "m")
        store.point(at: nil)
        #expect(store.board == nil)
    }

    @Test func chipsPublishAndASuggestFailureKeepsTheOthers() async {
        let rows = [WorkflowBoard.Row(n: "2", name: "a", display: .stage(.verify))]
        let chips = CadenceChips.make(rows: rows, next: nil, drift: 0, suggest: [.init(subject: "s", evidence: "e")],
                                      decisions: [:], reviewerModel: nil, reviewerEffort: nil)
        let shown: WorkflowBoard = {
            var copy = WorkflowBoard(milestone: "m", rows: rows)
            copy.chips = chips
            return copy
        }()
        let store = WorkflowStore(source: { _ in .success(shown) })
        store.point(at: "/p")
        await settle { store.board != nil }
        #expect(store.board?.chips.map(\.skill) == ["/cadence:cad-coverage", "/cadence:cad-minimalism-review", "/cadence:cad-suggest"])
        #expect(store.board?.chips[1].innerRole == "cad-reviewer: unknown / unknown")
        let failed: WorkflowBoard = {
            var copy = shown
            copy.chips = Array(chips.dropLast())
            copy.suggestReason = "Cadence suggest timed out after 20 seconds."
            return copy
        }()
        let second = WorkflowStore(source: { _ in .success(failed) })
        second.point(at: "/p")
        await settle { second.board != nil }
        #expect(second.board?.chips.count == 2)
        #expect(second.board?.suggestReason?.contains("timed out") == true)
    }

    @Test func decisionCountsReadContextAndSkipUnreadable() throws {
        let dir = NSTemporaryDirectory() + "chips-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/.planning/phases/1.1", withIntermediateDirectories: true)
        try "## Durable decisions\n- D-01 (a): x\n- D-02 (b): y\n".write(toFile: dir + "/.planning/phases/1.1/CONTEXT.md", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let rows = [WorkflowBoard.Row(n: "1.1", name: "a", display: .stage(.planned)),
                    WorkflowBoard.Row(n: "9", name: "b", display: .stage(.planned)),
                    WorkflowBoard.Row(n: "1.1x", name: "c", display: .stage(.planned))]
        #expect(CadenceChips.decisionCounts(project: dir, rows: rows) == ["1.1": 2])
    }

    @Test func configCheckPublishesRowsAndAFailureKeepsTheStrip() async throws {
        let health = CadenceHealth(drift: .success(0), audit: .success(.init(total: 1, broken: 0, kinds: [])), outstanding: .success(0))
        let ok = try CadenceConfigCheck.parse(
            #"{"ok":true,"values":{"workflow.plan_check":true,"workflow.verifier":true,"planning.code_map":false,"review.triggers.plan.gate":"advisory","review.triggers.diff.gate":"off","review.triggers.risk_surface.gate":"blocking","review.triggers.phase_diff.gate":"off"},"warnings":["retired key"]}"#,
            retry: { "" }).get()
        #expect(ok.rows.map(\.key) == CadenceConfigCheck.recommended.map(\.key))
        #expect(ok.rows.filter(\.differs).map(\.key) == ["planning.code_map"])
        let failed = WorkflowBoard(milestone: "m", rows: [], health: health, configCheck: .failure(.init(reason: "config broke")))
        let store = WorkflowStore(source: { _ in .success(failed) })
        store.point(at: "/p")
        await settle { store.board != nil }
        #expect(store.board?.health == health)
        #expect(store.board?.configCheck == .failure(.init(reason: "config broke")))
    }

    @Test func refreshPublishesHealthOnceAndAStatusFailureShowsNoStrip() async {
        let calls = Gate()
        let withHealth = WorkflowBoard(milestone: "m", rows: [], health: CadenceHealth(drift: .success(2), audit: .success(.init(total: 1, broken: 0, kinds: [])), outstanding: .success(3)))
        let store = WorkflowStore(source: { _ in
            _ = calls.enter()
            return calls.calls < 3 ? .success(withHealth) : .failure(.init(reason: "status broke"))
        })
        store.point(at: "/p")
        await settle { store.board != nil }
        #expect(store.board?.health?.lines.map(\.text) == ["2", "0/1", "3", "0", "0"])
        var published = 0
        let watch = store.$board.dropFirst().sink { _ in published += 1 }
        store.requestRefresh()
        await settle { calls.calls >= 2 }
        await settle { false }
        #expect(published == 0)
        store.requestRefresh()
        await settle { store.failure != nil }
        #expect(store.failure == "status broke")
        #expect(store.board == nil)
        watch.cancel()
    }

    @Test func failureShowsReasonAndNoBoard() async {
        let store = WorkflowStore(source: { _ in .failure(.init(reason: "no node")) })
        store.point(at: "/p")
        await settle { store.failure != nil }
        #expect(store.failure == "no node")
        #expect(store.board == nil)
    }

    @Test func staleGenerationIsDropped() async {
        let gate = Gate()
        let store = WorkflowStore(source: { project in
            if project == "/old" { gate.release.wait() }
            return .success(WorkflowBoard(milestone: project, rows: []))
        })
        store.point(at: "/old")
        store.point(at: "/new")
        gate.release.signal()
        await settle { store.board != nil }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.board?.milestone == "/new")
    }

    @Test func requestDuringRefreshGivesExactlyOneMore() async {
        let gate = Gate()
        let store = WorkflowStore(source: { _ in
            if gate.enter() == 1 { gate.release.wait() }
            return .success(WorkflowBoard(milestone: "m", rows: []))
        })
        store.point(at: "/p")
        await settle { gate.calls == 1 }
        store.requestRefresh()
        store.requestRefresh()
        store.requestRefresh()
        gate.release.signal()
        await settle { gate.calls >= 2 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(gate.calls == 2)
    }

    @Test func liveSourceOnAFolderWithoutPlanningGivesAReason() {
        let dir = NSTemporaryDirectory()
        guard case .failure(let problem) = WorkflowStore.liveSource(dir) else { Issue.record("expected failure"); return }
        #expect(problem.reason.contains(".planning"))
    }
}

/// Records deliveries, source calls and the liveness answer of a stub.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _sourceCalls = 0
    private var _off: String?
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    var sourceCalls: Int { lock.lock(); defer { lock.unlock() }; return _sourceCalls }
    var off: String? {
        get { lock.lock(); defer { lock.unlock() }; return _off }
        set { lock.lock(); _off = newValue; lock.unlock() }
    }
    func add(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
    func countSource() { lock.lock(); _sourceCalls += 1; lock.unlock() }
}

@MainActor @Suite struct WorkflowPanelTests {
    private func board(_ status: String, hasContext: Bool, skip: Bool = false, broken: Int = 0) -> WorkflowBoard {
        let st = CadenceStatus(current: "1", total: 1, cycle: nil, phases: [.init(n: "1", name: "a", status: status)], cursorNext: nil)
        let roles = Dictionary(uniqueKeysWithValues: CadenceConfig.agents.map { ($0, CadenceConfig.Role(model: "sonnet", effort: "medium")) })
        let cfg = CadenceConfig(skipDiscuss: skip, planCheck: true, roles: roles)
        let audit: Result<Int, CadenceLocator.Failure> = .success(broken)
        let (next, ahead) = WorkflowBoard.derive(status: st, config: cfg, hasContext: hasContext, audit: audit)
        return WorkflowBoard(milestone: "m", rows: [], status: st, config: cfg, audit: audit, next: next, skipAhead: ahead)
    }

    private func store(_ board: WorkflowBoard, _ probe: Probe, defaults: UserDefaults? = nil,
                       labels: @escaping WorkflowLabels = WorkflowStore.liveLabels) -> WorkflowStore {
        let suite = defaults ?? UserDefaults(suiteName: "WorkflowPanelTests.\(UUID().uuidString)")!
        return WorkflowStore(
            source: { _ in probe.countSource(); return .success(board) },
            liveness: { _ in probe.off },
            routing: StageRouting(defaults: suite),
            makeDeliver: { _ in { probe.add($0); return .sent } },
            labels: labels)
    }

    private func start(_ store: WorkflowStore) async {
        store.point(at: "/p", base: "base")
        for _ in 0..<300 where store.panel == nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func contextPressDeliversOneOpusHighLine() async {
        let probe = Probe()
        let store = store(board("unplanned", hasContext: false), probe)
        await start(store)
        await store.press()
        #expect(probe.lines == ["Cadence stage: skill=/cadence:cad-context phase=1 model=opus effort=high"])
    }

    @Test func executePressDeliversNoneNone() async {
        let probe = Probe()
        let store = store(board("planned", hasContext: true), probe)
        await start(store)
        await store.press()
        #expect(probe.lines == ["Cadence stage: skill=/cadence:cad-execute phase=1 model=none effort=none"])
    }

    @Test func settingsChangeAfterRenderDoesNotChangeTheLine() async {
        let probe = Probe()
        let defaults = UserDefaults(suiteName: "WorkflowPanelTests.\(UUID().uuidString)")!
        let store = store(board("unplanned", hasContext: false), probe, defaults: defaults)
        await start(store)
        StageRouting(defaults: defaults).set(.init(model: "haiku", effort: "low"), for: .context)
        await store.press()
        #expect(probe.lines == ["Cadence stage: skill=/cadence:cad-context phase=1 model=opus effort=high"])
    }

    @Test func overrideCarriesTheReason() async {
        let probe = Probe()
        let store = store(board("unplanned", hasContext: false), probe)
        await start(store)
        #expect(store.panel?.override?.stage == .plan)
        #expect(store.panel?.overrideReason?.hasPrefix("G1") == true)
        let sent = await store.sendOverride(reason: "no context needed")
        #expect(sent)
        #expect(probe.lines == ["Cadence stage: skill=/cadence:cad-plan phase=1 model=none effort=none reason: no context needed"])
    }

    @Test func hostileReasonIsFlattenedAndCreatesNoFile() async {
        try? FileManager.default.removeItem(atPath: "/tmp/ac5")
        let probe = Probe()
        let store = store(board("unplanned", hasContext: false), probe)
        await start(store)
        _ = await store.sendOverride(reason: "x\n$(touch /tmp/ac5)")
        #expect(probe.lines.count == 1)
        #expect(!probe.lines[0].contains("\n"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/ac5"))
    }

    @Test func emptyAndOverLongReasonsDeliverNothing() async {
        let probe = Probe()
        let store = store(board("unplanned", hasContext: false), probe)
        await start(store)
        #expect(await store.sendOverride(reason: "  ") == false)
        #expect(await store.sendOverride(reason: String(repeating: "r", count: 2000)) == false)
        #expect(probe.lines.isEmpty)
        #expect(store.message != nil)
    }

    @Test func skipDiscussUnblocksPlanAndOffersNoPlanOverride() async {
        let probe = Probe()
        let store = store(board("unplanned", hasContext: false, skip: true), probe)
        await start(store)
        #expect(store.panel?.next?.stage == .plan)
        #expect(store.panel?.button == .enabled)
        #expect(store.panel?.override?.stage != .plan)
    }

    @Test func blockedMilestoneGateDeliversNothingOnPressButOverrideSends() async {
        let probe = Probe()
        let store = store(board("complete", hasContext: true, broken: 2), probe)
        await start(store)
        guard case .off(let why)? = store.panel?.button else { Issue.record("expected off"); return }
        #expect(why.hasPrefix("G4"))
        await store.press()
        #expect(probe.lines.isEmpty)
        #expect(await store.sendOverride(reason: "accepted") == true)
        #expect(probe.lines.count == 1)
    }

    @Test func noDashboardWindowTurnsTheButtonOffAndNamesTheBase() async {
        let probe = Probe()
        probe.off = "No orchestrator window to send to for base."
        let store = store(board("planned", hasContext: true), probe)
        await start(store)
        #expect(store.panel?.button == .off("No orchestrator window to send to for base."))
        await store.press()
        #expect(probe.lines.isEmpty)
    }

    @Test func windowsChangeFlipsTheButtonWithoutAStatusRun() async {
        let probe = Probe()
        probe.off = "No orchestrator window to send to for base."
        let store = store(board("planned", hasContext: true), probe)
        await start(store)
        let before = probe.sourceCalls
        probe.off = nil
        store.recheckLive()
        for _ in 0..<300 where store.panel?.button != .enabled { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.panel?.button == .enabled)
        #expect(probe.sourceCalls == before)
    }

    @Test func aLivenessErrorShowsItsText() async {
        let probe = Probe()
        probe.off = "Could not ask tmux about base: boom"
        let store = store(board("planned", hasContext: true), probe)
        await start(store)
        #expect(store.panel?.button == .off("Could not ask tmux about base: boom"))
    }

    @Test func roleRowsPerStage() {
        func rows(_ stage: WorkflowGates.Stage, board b: WorkflowBoard) -> [String] {
            var b = b
            b.next = .init(stage: stage, phase: "1", reason: nil)
            return WorkflowPanel.make(board: b, live: .live, routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!)).roles.map(\.name)
        }
        let b = board("planned", hasContext: true)
        #expect(rows(.context, board: b) == ["cad-assumptions-analyzer"])
        #expect(rows(.plan, board: b) == ["cad-planner", "cad-plan-checker"])
        #expect(rows(.execute, board: b) == ["cad-executor"])
        #expect(rows(.verify, board: b) == ["cad-verifier"])
        #expect(rows(.milestone, board: b).isEmpty)
    }

    @Test func aMissingRoleShowsUnknown() {
        var b = board("planned", hasContext: true)
        b.config?.roles = [:]
        let panel = WorkflowPanel.make(board: b, live: .live, routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        #expect(panel.roles == [.init(name: "cad-executor", text: "unknown")])
    }

    private func chipBoard(_ chips: [CadenceChip]) -> WorkflowBoard {
        var b = board("planned", hasContext: true)
        b.chips = chips
        return b
    }

    private let coverage = CadenceChip(skill: "/cadence:cad-coverage", phase: "2", rule: "board rule: x")

    @Test func chipPressDeliversOneUtilityLineFromTheDisplayedEntry() async {
        let probe = Probe()
        let defaults = UserDefaults(suiteName: "WorkflowPanelTests.\(UUID().uuidString)")!
        let store = store(chipBoard([coverage]), probe, defaults: defaults)
        await start(store)
        StageRouting(defaults: defaults).setUtility(.init(model: "haiku", effort: "low"))
        await store.pressChip(coverage)
        #expect(probe.lines == ["Cadence stage: skill=/cadence:cad-coverage phase=2 model=sonnet effort=none"])
    }

    @Test func auditAndDecisionReviewChipLines() async {
        let probe = Probe()
        let store = store(chipBoard([]), probe)
        await start(store)
        await store.pressChip(.init(skill: "/cadence:cad-audit", phase: nil, rule: "r"))
        await store.pressChip(.init(skill: "/cadence:cad-decision-review", phase: "2",
                                    argument: ".planning/phases/2/CONTEXT.md", rule: "r"))
        #expect(probe.lines == [
            "Cadence stage: skill=/cadence:cad-audit model=sonnet effort=none",
            "Cadence stage: skill=/cadence:cad-decision-review phase=2 arg=.planning/phases/2/CONTEXT.md model=sonnet effort=none"])
    }

    @Test func pricedPairSendsTheConfigLineAndRefusesWhenHeldOrBad() async {
        let probe = Probe()
        let store = store(chipBoard([]), probe)
        await start(store)
        await store.pressConfigPair(action: "workflow.max_plan_tasks", proposed: "7")
        #expect(probe.lines == ["Cadence stage: skill=/cadence:cad-config arg=workflow.max_plan_tasks=7 model=sonnet effort=none"])
        await store.pressConfigPair(action: "--global", proposed: "7")
        #expect(probe.lines.count == 1 && store.message?.contains("--global") == true)

        let heldProbe = Probe()
        let heldStore = self.store(chipBoard([]), heldProbe)
        await start(heldStore)
        heldStore.setRows([WorkerRow(agentId: "cad-config", status: "running", taskTitle: nil, lastEvent: nil,
                                     createdAt: "2026-11-11 08:00:00")])
        await heldStore.pressConfigPair(action: "workflow.max_plan_tasks", proposed: "7")
        #expect(heldProbe.lines.isEmpty && heldStore.message?.contains("cad-config") == true)
    }

    @Test func heldChipLabelAndNoLiveWindowDeliverNothing() async {
        let probe = Probe()
        let store = store(chipBoard([coverage]), probe)
        await start(store)
        store.setRows([WorkerRow(agentId: "cad-coverage-p2", status: "running", taskTitle: nil, lastEvent: nil,
                                 createdAt: "2026-11-11 08:00:00")])
        await store.pressChip(coverage)
        #expect(probe.lines.isEmpty)
        #expect(store.message?.contains("cad-coverage-p2") == true)

        let off = Probe()
        off.off = "No orchestrator window."
        let offStore = self.store(chipBoard([coverage]), off)
        await start(offStore)
        await offStore.pressChip(coverage)
        #expect(off.lines.isEmpty)
        #expect(offStore.message == "No orchestrator window.")
    }

    @Test func doubleChipPressDeliversOneLine() async {
        let probe = Probe()
        let release = DispatchSemaphore(value: 0)
        let board = chipBoard([coverage])
        let store = WorkflowStore(
            source: { _ in .success(board) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeDeliver: { _ in { probe.add($0); release.wait(); return .sent } })
        await start(store)
        // The stub holds the first send in flight, so the second press always meets the in-flight guard.
        let first = Task { await store.pressChip(coverage) }
        for _ in 0..<300 where probe.lines.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        await store.pressChip(coverage)
        release.signal()
        await first.value
        #expect(probe.lines.count == 1)
    }

    private func configBoard(flagged: Set<String>) -> WorkflowBoard {
        var b = board("planned", hasContext: true)
        let rows = CadenceConfigCheck.recommended.map { entry in
            CadenceConfigCheck.Row(key: entry.key, current: flagged.contains(entry.key) ? nil : entry.value,
                                   recommended: entry.value, differs: flagged.contains(entry.key))
        }
        b.configCheck = .success(CadenceConfigCheck(rows: rows, warnings: [], reviewerModel: "sonnet", reviewerEffort: "medium"))
        return b
    }

    private func check(_ b: WorkflowBoard) -> CadenceConfigCheck? {
        if case .success(let found)? = b.configCheck { return found }
        return nil
    }

    @Test func configFixPressDeliversOnePairLineAndUnflaggedHasNone() async {
        let probe = Probe()
        let b = configBoard(flagged: ["workflow.plan_check", "review.triggers.diff.gate"])
        let store = store(b, probe)
        await start(store)
        let found = check(b)!
        #expect(found.fixChip(key: "workflow.verifier") == nil)
        await store.pressChip(found.fixChip(key: "workflow.plan_check")!)
        // Both chips share the cad-config label: show then end the first worker so its pending state clears.
        let cfgRow = { (status: String) in WorkerRow(agentId: "cad-config", status: status, taskTitle: nil, lastEvent: nil,
                                                      createdAt: "2026-11-11 08:00:00") }
        store.setRows([cfgRow("running")])
        store.setRows([cfgRow("dead")])
        await store.pressChip(found.fixChip(key: "review.triggers.diff.gate")!)
        #expect(probe.lines == [
            "Cadence stage: skill=/cadence:cad-config arg=workflow.plan_check=true model=sonnet effort=none",
            "Cadence stage: skill=/cadence:cad-config arg=review.triggers.diff.gate=off model=sonnet effort=none",
        ])
        #expect(probe.lines.allSatisfy { !$0.contains("--global") })
    }

    @Test func fixAllHoldsEveryFlaggedPairInOneLine() async {
        let probe = Probe()
        let b = configBoard(flagged: ["workflow.plan_check", "planning.code_map"])
        let store = store(b, probe)
        await start(store)
        await store.pressChip(check(b)!.fixAllChip()!)
        #expect(probe.lines == ["Cadence stage: skill=/cadence:cad-config arg=workflow.plan_check=true planning.code_map=true model=sonnet effort=none"])
        #expect(check(configBoard(flagged: ["workflow.plan_check"]))!.fixAllChip() == nil)
        #expect(check(configBoard(flagged: []))!.fixAllChip() == nil)
    }

    @Test func diffGateFixCarriesOff() async {
        let probe = Probe()
        let b = configBoard(flagged: ["review.triggers.diff.gate"])
        let store = store(b, probe)
        await start(store)
        await store.pressChip(check(b)!.fixChip(key: "review.triggers.diff.gate")!)
        #expect(probe.lines == ["Cadence stage: skill=/cadence:cad-config arg=review.triggers.diff.gate=off model=sonnet effort=none"])
    }

    @Test func configFixWithNoLiveWindowDeliversNothingAndDoubleDeliversOne() async {
        let off = Probe()
        off.off = "No orchestrator window."
        let b = configBoard(flagged: ["workflow.plan_check"])
        let offStore = store(b, off)
        await start(offStore)
        await offStore.pressChip(check(b)!.fixChip(key: "workflow.plan_check")!)
        #expect(off.lines.isEmpty)

        let probe = Probe()
        // A slow delivery keeps the first press in flight, so the second meets the one-send-at-a-time guard.
        let store = WorkflowStore(
            source: { _ in .success(b) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: "WorkflowPanelTests.\(UUID().uuidString)")!),
            makeDeliver: { _ in { Thread.sleep(forTimeInterval: 0.2); probe.add($0); return .sent } })
        await start(store)
        let fix = check(b)!.fixChip(key: "workflow.plan_check")!
        async let first: Void = store.pressChip(fix)
        async let second: Void = store.pressChip(fix)
        _ = await (first, second)
        #expect(probe.lines.count == 1)
    }
}

private final class OverlayProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _labels: Result<Set<String>, SessionCheckFailure> = .success([])
    private var _lines: [String] = []
    private var _kills: [String] = []
    private var _gate: DispatchSemaphore?
    /// When set, the labels closure waits on it, so a test sees the state before the tmux answer.
    var gate: DispatchSemaphore? {
        get { lock.lock(); defer { lock.unlock() }; return _gate }
        set { lock.lock(); _gate = newValue; lock.unlock() }
    }
    var labels: Result<Set<String>, SessionCheckFailure> {
        get { lock.lock(); defer { lock.unlock() }; return _labels }
        set { lock.lock(); _labels = newValue; lock.unlock() }
    }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    var kills: [String] { lock.lock(); defer { lock.unlock() }; return _kills }
    func add(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
    func kill(_ label: String) { lock.lock(); _kills.append(label); lock.unlock() }
}

@MainActor @Suite struct WorkflowOverlayStoreTests {
    private func board(_ status: String) -> WorkflowBoard {
        let st = CadenceStatus(current: "1", total: 1, cycle: nil, phases: [.init(n: "1", name: "a", status: status)], cursorNext: nil)
        let roles = Dictionary(uniqueKeysWithValues: CadenceConfig.agents.map { ($0, CadenceConfig.Role(model: "sonnet", effort: "medium")) })
        let cfg = CadenceConfig(skipDiscuss: true, planCheck: true, roles: roles)
        let audit: Result<Int, CadenceLocator.Failure> = .success(0)
        let (next, ahead) = WorkflowBoard.derive(status: st, config: cfg, hasContext: true, audit: audit)
        return WorkflowBoard(milestone: "m", rows: [.init(n: "1", name: "a", display: .stage(.planned))],
                             status: st, config: cfg, audit: audit, next: next, skipAhead: ahead)
    }

    private func row(_ label: String, _ status: String, age: TimeInterval = 3600) -> WorkerRow {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: nil,
                         createdAt: format.string(from: clock.addingTimeInterval(-age)))
    }

    /// One fixed instant for the row ages and the store, so a slow run cannot age a young row past the starting window.
    private let clock = Date()

    private func store(_ probe: OverlayProbe, kill: WorkflowKill? = nil) -> WorkflowStore {
        let board = board("planned")
        let clock = clock
        return WorkflowStore(
            source: { _ in .success(board) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeDeliver: { _ in { probe.add($0); return .sent } },
            labels: { _ in probe.gate?.wait(); return probe.labels },
            kill: kill ?? { label, _ in
                Thread.sleep(forTimeInterval: 0.2)
                probe.kill(label)
                return MergeReview.Run(output: "", status: 0, failure: nil)
            },
            now: { clock })
    }

    private func start(_ store: WorkflowStore) async {
        store.point(at: "/p", base: "base")
        for _ in 0..<300 where store.panel == nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<300 where !until() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func runningExecuteRowShowsExecutingAndTurnsTheButtonOff() async {
        let probe = OverlayProbe()
        probe.labels = .success(["cad-execute-p1"])
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-execute-p1", "running")])
        await settle { store.overlays["1"]?.text == "executing" }
        #expect(store.overlays["1"]?.text == "executing")
        #expect(store.panel?.button == .off("executing"))
        await store.press()
        #expect(probe.lines.isEmpty)
    }

    @Test func emptyLivenessTurnsItDeadWithNoStatusRun() async {
        let probe = OverlayProbe()
        probe.labels = .success(["cad-execute-p1"])
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-execute-p1", "running")])
        await settle { store.overlays["1"]?.state == .running }
        probe.labels = .success([])
        store.recomputeOverlays()
        await settle { store.overlays["1"]?.state == .dead }
        #expect(store.overlays["1"]?.text == "dead worker")
        #expect(store.panel?.button == .off("dead worker"))
    }

    @Test func pendingQuestionShowsQuestionWaitingOnlyForARunningContextOverlay() async {
        let probe = OverlayProbe()
        probe.labels = .success(["cad-context-p1"])
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-context-p1", "running")])
        await settle { store.overlays["1"]?.state == .running }
        #expect(store.overlays["1"]?.text == "context running")
        store.setPendingQuestions(["cad-context-p1"])
        #expect(store.overlays["1"]?.text == "question waiting")
        #expect(store.overlays["1"]?.state == .running)
        #expect(store.panel?.button == .off("question waiting"))
        store.setPendingQuestions([])
        #expect(store.panel?.button == .off("context running"))
        #expect(store.overlays["1"]?.text == "context running")
    }

    @Test func aQuestionOfAnExecuteLabelShowsQuestionWaiting() async {
        let probe = OverlayProbe()
        probe.labels = .success(["cad-execute-p1"])
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-execute-p1", "running")])
        await settle { store.overlays["1"]?.state == .running }
        #expect(store.overlays["1"]?.text == "executing")
        store.setPendingQuestions(["cad-execute-p1"])
        #expect(store.overlays["1"]?.text == "question waiting")
    }

    @Test func aPlanOverlayShowsQuestionWaitingOnlyWithAPendingQuestionAndNotWhenDead() async {
        let probe = OverlayProbe()
        probe.labels = .success(["cad-plan-p1"])
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-plan-p1", "running")])
        await settle { store.overlays["1"]?.state == .running }
        #expect(store.overlays["1"]?.text == "plan running")
        store.setPendingQuestions(["cad-plan-p1"])
        #expect(store.overlays["1"]?.text == "question waiting")
        #expect(store.panel?.button == .off("question waiting"))
        store.setPendingQuestions([])
        #expect(store.overlays["1"]?.text == "plan running")
        probe.labels = .success([])
        store.recomputeOverlays()
        await settle { store.overlays["1"]?.state == .dead }
        store.setPendingQuestions(["cad-plan-p1"])
        #expect(store.overlays["1"]?.text == "dead worker")
    }

    @Test func aDeadOverlayShowsTheDeadTextNotQuestionWaiting() async {
        let probe = OverlayProbe()
        probe.labels = .success([])
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-context-p1", "running")])
        await settle { store.overlays["1"]?.state == .dead }
        store.setPendingQuestions(["cad-context-p1"])
        #expect(store.overlays["1"]?.text == "dead worker")
    }

    @Test func aLivenessErrorGivesAReasonAndAnOffButton() async {
        let probe = OverlayProbe()
        probe.labels = .failure(.init(reason: "tmux timed out"))
        let store = store(probe)
        await start(store)
        store.recomputeOverlays()
        await settle { store.panel?.button == .off("tmux timed out") }
        #expect(store.panel?.button == .off("tmux timed out"))
    }

    @Test func aLiveStageWindowWithNoRowTurnsTheButtonOff() async {
        let probe = OverlayProbe()
        probe.labels = .success(["cad-execute-p1"])
        let store = store(probe)
        await start(store)
        store.recomputeOverlays()
        await settle { store.panel?.button == .off("executing") }
        #expect(store.panel?.button == .off("executing"))
        await store.press()
        #expect(probe.lines.isEmpty)
    }

    @Test func aHeldRowGatesTheButtonBeforeTmuxAnswers() async {
        let probe = OverlayProbe()
        let gate = DispatchSemaphore(value: 0)
        probe.gate = gate
        probe.labels = .success(["cad-execute-p1"])
        let store = store(probe)
        store.point(at: "/p", base: "base")
        store.setRows([row("cad-execute-p1", "running")])
        await settle { store.panel != nil }
        #expect(store.panel?.button == .off("executing"))
        await store.press()
        #expect(probe.lines.isEmpty)
        gate.signal()
    }

    @Test func deadLabelsListsADeadRowOnlyWhileItsWindowIsGone() async {
        let probe = OverlayProbe()
        probe.labels = .success([])
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-context-p2", "running")])
        await settle { store.deadLabels.contains("cad-context-p2") }
        #expect(store.deadLabels == ["cad-context-p2"])
        probe.labels = .success(["cad-context-p2"])
        store.recomputeOverlays()
        await settle { store.deadLabels.isEmpty }
        #expect(store.deadLabels.isEmpty)
    }

    @Test func endedLabelsListsAFinishedRowOnlyWhileItsWindowIsGone() async {
        let probe = OverlayProbe()
        probe.labels = .success([])
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-plan-p4", "done")])
        await settle { store.endedLabels.contains("cad-plan-p4") }
        #expect(store.endedLabels == ["cad-plan-p4"])
        #expect(store.deadLabels.isEmpty)
        probe.labels = .success(["cad-plan-p4"])
        store.recomputeOverlays()
        await settle { store.endedLabels.isEmpty }
        #expect(store.endedLabels.isEmpty)
    }

    @Test func waitingAndDeadBlockPressAndOverrideAndMergedDoesNot() async {
        for (status, expected) in [("done", "waiting for merge"), ("running", "dead worker")] {
            let probe = OverlayProbe()
            let store = store(probe)
            await start(store)
            store.setRows([row("cad-execute-p1", status)])
            await settle { store.panel?.button == .off(expected) }
            #expect(store.panel?.button == .off(expected))
            await store.press()
            _ = await store.sendOverride(reason: "because")
            #expect(probe.lines.isEmpty)
        }
        let probe = OverlayProbe()
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-execute-p1", "merged")])
        store.recomputeOverlays()
        await settle { store.panel?.button == .enabled }
        #expect(store.panel?.button == .enabled)
        await store.press()
        #expect(probe.lines.count == 1)
    }

    @Test func clearKillsTheLabelOnceAndADoublePressRunsOnce() async {
        let probe = OverlayProbe()
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-execute-p1", "running")])
        await settle { store.overlays["1"]?.state == .dead }
        async let first: Void = store.clear("cad-execute-p1")
        async let second: Void = store.clear("cad-execute-p1")
        _ = await (first, second)
        #expect(probe.kills == ["cad-execute-p1"])
        store.setRows([row("cad-execute-p1", "dead")])
        await settle { store.panel?.button == .enabled }
        #expect(store.overlays["1"] == nil && store.panel?.button == .enabled)
    }

    @Test func aFailedClearKeepsTheDeadStateAndShowsTheOutput() async {
        let probe = OverlayProbe()
        let store = store(probe, kill: { _, _ in MergeReview.Run(output: "kill refused", status: 1, failure: nil) })
        await start(store)
        store.setRows([row("cad-execute-p1", "running")])
        await settle { store.overlays["1"]?.state == .dead }
        await store.clear("cad-execute-p1")
        #expect(store.overlays["1"]?.state == .dead)
        #expect(store.message?.contains("kill refused") == true)
    }

    private let fixChip = CadenceChip(skill: "/cadence:cad-config", phase: nil, argument: "workflow.plan_check=true", rule: "x")

    @Test func configWorkerHoldsTheFixButtonsByStateAndMergedReleasesThem() async {
        let cases: [(WorkerRow, Set<String>, WorkflowOverlay.State?)] = [
            (row("cad-config", "running", age: 2), [], .running),
            (row("cad-config", "running"), ["cad-config"], .running),
            (row("cad-config", "done"), [], .waitingForMerge),
            (row("cad-config", "running"), [], .dead),
            (row("cad-config", "merged"), [], nil),
        ]
        for (workerRow, live, expected) in cases {
            let probe = OverlayProbe()
            probe.labels = .success(live)
            let store = store(probe)
            await start(store)
            store.setRows([workerRow])
            await settle { store.panel?.configHold == expected }
            #expect(store.panel?.configHold == expected)
            await store.pressChip(fixChip)
            if expected == nil {
                #expect(probe.lines.count == 1)
            } else {
                #expect(probe.lines.isEmpty)
                #expect(store.held == "cad-config")
                #expect(store.message?.contains("cad-config") == true)
            }
        }
    }

    @Test func aHeldLabelDeliversNothingOffersClearThenDeliversOnceAfterClear() async {
        let probe = OverlayProbe()
        let store = store(probe)
        await start(store)
        store.setRows([row("cad-execute-p1", "blocked")])
        await store.press()
        #expect(probe.lines.isEmpty)
        #expect(store.held == "cad-execute-p1")
        #expect(store.message?.contains("cad-execute-p1") == true && store.message?.contains("blocked") == true)
        store.setRows([row("cad-execute-p1", "dead")])
        #expect(store.held == nil)
        await settle { store.panel?.button == .enabled }
        await store.press()
        #expect(probe.lines.count == 1)
    }
}

@MainActor @Suite struct ContextOpenStoreTests {
    private let clock = Date()

    private func board(_ display: WorkflowStageMap.Display) -> WorkflowBoard {
        WorkflowBoard(milestone: "m", rows: [.init(n: "3", name: "a", display: display)])
    }

    private func row(_ label: String, _ status: String) -> WorkerRow {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: nil,
                         createdAt: format.string(from: clock.addingTimeInterval(-3600)))
    }

    private func open(_ display: WorkflowStageMap.Display, rows: [WorkerRow] = [], live: Set<String> = []) async -> Set<String> {
        let shown = board(display), clock = clock
        let store = WorkflowStore(
            source: { _ in .success(shown) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            labels: { _ in .success(live) }, now: { clock })
        store.point(at: "/p", base: "base")
        for _ in 0..<300 where store.panel == nil { try? await Task.sleep(for: .milliseconds(10)) }
        store.setRows(rows)
        store.recomputeOverlays()
        try? await Task.sleep(for: .milliseconds(150))
        return store.contextOpen
    }

    @Test func contextStageWithNoWorkerOffersOpen() async {
        #expect(await open(.stage(.context)) == ["3"])
    }

    @Test func aRunningWaitingOrDeadContextWorkerOffersOpen() async {
        let planned = WorkflowStageMap.Display.stage(.planned)
        #expect(await open(planned, rows: [row("cad-context-p3", "running")], live: ["cad-context-p3"]) == ["3"])
        #expect(await open(planned, rows: [row("cad-context-p3", "finished")]) == ["3"])
        #expect(await open(planned, rows: [row("cad-context-p3", "running")]) == ["3"])
    }

    @Test func aPlannedPhaseWithNoContextWorkerGetsNoOpen() async {
        #expect(await open(.stage(.planned)).isEmpty)
        #expect(await open(.stage(.planned), rows: [row("cad-execute-p3", "running")], live: ["cad-execute-p3"]).isEmpty)
    }

    @Test func theStageTableHoldsContextAndPlanAndReadsTheDispatchStageOfALabel() {
        #expect(ContextCardState.screenStages == [.context, .plan, .execute, .verify, .milestone])
        #expect(ContextCardState.dispatchStage(ofLabel: "cad-context-p3") == .context)
        #expect(ContextCardState.dispatchStage(ofLabel: "cad-context-p1-1") == .context)
        #expect(ContextCardState.dispatchStage(ofLabel: "cad-execute-p3") == .execute)
        #expect(ContextCardState.hasScreen(label: "cad-context-p3"))
        #expect(ContextCardState.hasScreen(label: "cad-execute-p3"))
        #expect(ContextCardState.hasScreen(label: "cad-plan-p3"))
        #expect(ContextCardState.hasScreen(label: "cad-milestone-p3"))
        #expect(!ContextCardState.hasScreen(label: "cad-milestone-p3x"))
        #expect(!ContextCardState.hasScreen(label: "cad-config"))
    }
}

@MainActor @Suite struct PlanOpenStoreTests {
    private let clock = Date()

    private func row(_ label: String, _ status: String) -> WorkerRow {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: nil,
                         createdAt: format.string(from: clock.addingTimeInterval(-3600)))
    }

    private func open(_ display: WorkflowStageMap.Display, rows: [WorkerRow] = [], live: Set<String> = []) async -> Set<String> {
        let shown = WorkflowBoard(milestone: "m", rows: [.init(n: "4", name: "a", display: display)]), clock = clock
        let store = WorkflowStore(
            source: { _ in .success(shown) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            labels: { _ in .success(live) }, now: { clock })
        store.point(at: "/p", base: "base")
        for _ in 0..<300 where store.panel == nil { try? await Task.sleep(for: .milliseconds(10)) }
        store.setRows(rows)
        store.recomputeOverlays()
        try? await Task.sleep(for: .milliseconds(150))
        return store.planOpen
    }

    @Test func aPlanWorkerRunningWaitingOrDeadOffersOpenPlan() async {
        let context = WorkflowStageMap.Display.stage(.context)
        #expect(await open(context, rows: [row("cad-plan-p4", "running")], live: ["cad-plan-p4"]) == ["4"])
        #expect(await open(context, rows: [row("cad-plan-p4", "finished")]) == ["4"])
        #expect(await open(context, rows: [row("cad-plan-p4", "running")]) == ["4"])
    }

    @Test func aPlannedPhaseWithNoOverlayOffersOpenPlan() async {
        #expect(await open(.stage(.planned)) == ["4"])
    }

    @Test func aContextStagePhaseOrAnExecuteOverlayOnlyGetsNoOpenPlan() async {
        #expect(await open(.stage(.context)).isEmpty)
        #expect(await open(.stage(.context), rows: [row("cad-execute-p4", "running")], live: ["cad-execute-p4"]).isEmpty)
    }
}

@MainActor @Suite struct UATOpenStoreTests {
    private let clock = Date()

    private func row(_ label: String, _ status: String) -> WorkerRow {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: nil,
                         createdAt: format.string(from: clock.addingTimeInterval(-3600)))
    }

    private func open(_ display: WorkflowStageMap.Display, rows: [WorkerRow] = [], live: Set<String> = []) async -> Set<String> {
        let shown = WorkflowBoard(milestone: "m", rows: [.init(n: "3", name: "a", display: display)]), clock = clock
        let store = WorkflowStore(
            source: { _ in .success(shown) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            labels: { _ in .success(live) }, now: { clock })
        store.point(at: "/p", base: "base")
        for _ in 0..<300 where store.panel == nil { try? await Task.sleep(for: .milliseconds(10)) }
        store.setRows(rows)
        store.recomputeOverlays()
        try? await Task.sleep(for: .milliseconds(150))
        return store.uatOpen
    }

    @Test func aVerifyStagePhaseWithNoWorkerOffersOpenUAT() async {
        #expect(await open(.stage(.verify)) == ["3"])
    }

    @Test func aVerifyWorkerRunningWaitingOrDeadOffersOpenUAT() async {
        let planned = WorkflowStageMap.Display.stage(.planned)
        #expect(await open(planned, rows: [row("cad-verify-p3", "running")], live: ["cad-verify-p3"]) == ["3"])
        #expect(await open(planned, rows: [row("cad-verify-p3", "finished")]) == ["3"])
        #expect(await open(planned, rows: [row("cad-verify-p3", "running")]) == ["3"])
    }

    @Test func aPlannedPhaseWithNoVerifyWorkerGetsNoOpenUAT() async {
        #expect(await open(.stage(.planned)).isEmpty)
        #expect(await open(.stage(.planned), rows: [row("cad-execute-p3", "running")], live: ["cad-execute-p3"]).isEmpty)
    }
}

@MainActor @Suite struct ExecuteOpenStoreTests {
    private let clock = Date()

    private func row(_ label: String, _ status: String) -> WorkerRow {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: nil,
                         createdAt: format.string(from: clock.addingTimeInterval(-3600)))
    }

    private func open(plans: [String] = [], rows: [WorkerRow] = [], live: Set<String> = []) async -> Set<String> {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: "\(dir)/.planning/phases/3", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for name in plans { FileManager.default.createFile(atPath: "\(dir)/.planning/phases/3/\(name)", contents: Data()) }
        let shown = WorkflowBoard(milestone: "m", rows: [.init(n: "3", name: "a", display: .stage(.planned))]), clock = clock
        let store = WorkflowStore(
            source: { _ in .success(shown) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            labels: { _ in .success(live) }, now: { clock })
        store.point(at: dir, base: "base")
        for _ in 0..<300 where store.panel == nil { try? await Task.sleep(for: .milliseconds(10)) }
        store.setRows(rows)
        store.recomputeOverlays()
        try? await Task.sleep(for: .milliseconds(150))
        return store.executeOpen
    }

    @Test func anExecuteWorkerRunningWaitingOrDeadOffersOpenExecute() async {
        #expect(await open(rows: [row("cad-execute-p3", "running")], live: ["cad-execute-p3"]) == ["3"])
        #expect(await open(rows: [row("cad-execute-p3", "finished")]) == ["3"])
        #expect(await open(rows: [row("cad-execute-p3", "running")]) == ["3"])
    }

    @Test func aPhaseWithPlansAndNoOverlayOffersOpenExecute() async {
        #expect(await open(plans: ["PLAN-1.md"]) == ["3"])
    }

    @Test func noPlansAndNoExactLabelOffersNothing() async {
        #expect(await open().isEmpty)
        #expect(await open(rows: [row("cad-execute-p3-1", "running")], live: ["cad-execute-p3-1"]).isEmpty)
    }
}

@MainActor @Suite struct PlanReadyTextTests {
    private let clock = Date()

    private func row(_ label: String, _ status: String) -> WorkerRow {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: nil,
                         worktreePath: "/p/.claude/worktrees/w", createdAt: format.string(from: clock.addingTimeInterval(-3600)))
    }

    private func overlayText(_ label: String, _ status: String, live: Set<String> = [], files: Bool) async -> String? {
        let shown = WorkflowBoard(milestone: "m", rows: [.init(n: "4", name: "a", display: .stage(.context))]), clock = clock
        let store = WorkflowStore(
            source: { _ in .success(shown) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            labels: { _ in .success(live) }, planFiles: { _, _, _ in files }, now: { clock })
        store.point(at: "/p", base: "base")
        for _ in 0..<300 where store.panel == nil { try? await Task.sleep(for: .milliseconds(10)) }
        store.setRows([row(label, status)])
        store.recomputeOverlays()
        try? await Task.sleep(for: .milliseconds(200))
        return store.overlays["4"]?.text
    }

    @Test func finishedPlanWorkerWithFilesShowsReady() async {
        #expect(await overlayText("cad-plan-p4", "done", files: true) == "Plan ready for review")
    }

    @Test func finishedPlanWorkerWithoutFilesKeepsWaitingForMerge() async {
        #expect(await overlayText("cad-plan-p4", "done", files: false) == "waiting for merge")
    }

    @Test func otherStagesKeepWaitingForMerge() async {
        #expect(await overlayText("cad-context-p4", "done", files: true) == "waiting for merge")
        #expect(await overlayText("cad-execute-p4", "done", files: true) == "waiting for merge")
    }

    @Test func runningPlanWorkerShowsPlanRunning() async {
        #expect(await overlayText("cad-plan-p4", "running", live: ["cad-plan-p4"], files: true) == "plan running")
    }
}

@Suite struct BoardAuditVerdictTests {
    private let okAudit = #"{"ok":true,"requirements":[],"counts":{"total":0,"traced":0,"broken":0,"deferred":0}}"#
    private let okCoverage = #"{"ok":true,"breaks":[]}"#

    private func verdict(_ audit: String, _ coverage: String) throws -> (Int, WorkflowGates.Verdict) {
        let count = try MilestoneAudit.parse(audit: audit, coverage: coverage).get().failCount
        let st = CadenceStatus(current: "1", total: 1, cycle: nil, phases: [.init(n: "1", name: "a", status: "complete")], cursorNext: nil)
        return (count, WorkflowGates.verdict(for: .milestone, status: st, hasContext: true, skipDiscuss: false, audit: .success(count)))
    }

    @Test func aCoverageBreakAloneBlocksG4() throws {
        let (count, v) = try verdict(okAudit, #"{"ok":true,"breaks":[{"phase":1,"id":"AC1","break":"uncovered"}]}"#)
        #expect(count > 0)
        guard case .blocked = v else { Issue.record("expected blocked"); return }
    }

    @Test func driftAloneBlocksG4() throws {
        let audit = #"{"ok":true,"requirements":[],"counts":{"total":0,"traced":0,"broken":0,"deferred":0},"version_drift":{"doc_version":"v1","published_as":"v1.0.0","cycle_state":"open"}}"#
        let (count, v) = try verdict(audit, okCoverage)
        #expect(count > 0)
        guard case .blocked = v else { Issue.record("expected blocked"); return }
    }

    @Test func aCleanRunAllowsG4() throws {
        let (count, v) = try verdict(okAudit, okCoverage)
        #expect(count == 0)
        #expect(v == .allowed)
    }
}

extension WorkflowPanelTests {
    @Test func milestoneCloseSendsTheLineWithNoReason() async {
        let probe = Probe()
        let store = store(board("planned", hasContext: true), probe)
        await start(store)
        let entry = store.milestoneTarget?.routing
        #expect(store.milestoneTarget?.stage == .milestone && store.milestoneTarget?.phase == "1")
        #expect(await store.closeMilestone())
        let expected = try? WorkflowDispatch.line(stage: .milestone, phase: "1", routing: entry!, reason: nil).get()
        #expect(probe.lines == [expected ?? ""])
        #expect(probe.lines.first?.hasPrefix("Cadence stage: skill=/cadence:cad-milestone phase=1 model=") == true)
        #expect(probe.lines.first?.contains(" reason:") == false)
    }

    @Test func milestoneOverrideAddsTheReasonAndRefusesBlank() async {
        let probe = Probe()
        let store = store(board("planned", hasContext: true), probe)
        await start(store)
        #expect(await store.overrideMilestone(reason: "ship it"))
        #expect(probe.lines.count == 1 && probe.lines[0].hasSuffix(" reason: ship it"))
        #expect(await !store.overrideMilestone(reason: "   "))
        #expect(probe.lines.count == 1)
    }

    @Test func landSendsTheCadLandLineOnlyToALiveMilestoneWorker() async {
        let probe = Probe()
        let store = store(board("planned", hasContext: true), probe, labels: { _ in .success(["cad-milestone-p1"]) })
        await start(store)
        #expect(await !store.landMilestone())
        #expect(probe.lines.isEmpty)
        #expect(store.message?.contains("Nothing was sent") == true)
        store.setRows([WorkerRow(agentId: "cad-milestone-p1", status: "dead", taskTitle: nil, lastEvent: nil,
                                 createdAt: "2026-11-11 08:00:00")])
        #expect(await !store.landMilestone())
        #expect(probe.lines.isEmpty)
        store.setRows([WorkerRow(agentId: "cad-milestone-p1", status: "running", taskTitle: nil, lastEvent: nil,
                                 createdAt: "2026-11-11 08:00:00")])
        for _ in 0..<300 where store.milestoneState == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let routing = store.milestoneTarget!.routing
        #expect(await store.landMilestone())
        let expected = try? WorkflowDispatch.line(skill: "/cadence:cad-land", phase: "1", routing: routing).get()
        #expect(probe.lines == [expected ?? ""])
        #expect(probe.lines[0].hasPrefix("Cadence stage: skill=/cadence:cad-land phase=1 model="))
        #expect(!probe.lines[0].contains(" reason:") && !probe.lines[0].contains("arg="))
    }

    @Test func aHeldMilestoneWorkerRefusesBoth() async {
        let probe = Probe()
        let store = store(board("planned", hasContext: true), probe)
        await start(store)
        store.setRows([WorkerRow(agentId: "cad-milestone-p1", status: "running", taskTitle: nil, lastEvent: nil,
                                 createdAt: "2026-11-11 08:00:00")])
        #expect(await !store.closeMilestone())
        #expect(await !store.overrideMilestone(reason: "why"))
        #expect(probe.lines.isEmpty)
    }
}

private final class SendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _fail = false
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    var fail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fail }
        set { lock.lock(); _fail = newValue; lock.unlock() }
    }
    func send(_ line: String) -> InboxDelivery.Outcome {
        lock.lock(); defer { lock.unlock() }
        if _fail { return .failed("boom") }
        _lines.append(line)
        return .sent
    }
}

private final class MovableClock { var date = Date() }

/// FIX-01: a sent stage line counts as pending until its worker row or window shows, so a second press sends nothing.
@MainActor @Suite struct WorkflowPendingSendTests {
    private let clock = MovableClock()
    private let chip = CadenceChip(skill: "/cadence:cad-coverage", phase: "2", rule: "board rule: x")

    private func board() -> WorkflowBoard {
        let st = CadenceStatus(current: "1", total: 1, cycle: nil, phases: [.init(n: "1", name: "a", status: "planned")], cursorNext: nil)
        let roles = Dictionary(uniqueKeysWithValues: CadenceConfig.agents.map { ($0, CadenceConfig.Role(model: "sonnet", effort: "medium")) })
        let cfg = CadenceConfig(skipDiscuss: true, planCheck: true, roles: roles)
        let audit: Result<Int, CadenceLocator.Failure> = .success(0)
        let (next, ahead) = WorkflowBoard.derive(status: st, config: cfg, hasContext: true, audit: audit)
        return WorkflowBoard(milestone: "m", rows: [.init(n: "1", name: "a", display: .stage(.planned))],
                             status: st, config: cfg, audit: audit, next: next, skipAhead: ahead)
    }

    private func row(_ label: String, _ status: String) -> WorkerRow {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return WorkerRow(agentId: label, status: status, taskTitle: nil, lastEvent: nil,
                         createdAt: format.string(from: clock.date.addingTimeInterval(-3600)))
    }

    private func store(_ probe: SendProbe) -> WorkflowStore {
        let shown = board(), clock = clock
        return WorkflowStore(
            source: { _ in .success(shown) }, liveness: { _ in nil },
            routing: StageRouting(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeDeliver: { _ in { probe.send($0) } },
            labels: { _ in .success([]) }, now: { clock.date })
    }

    private func start(_ store: WorkflowStore, folder: String = "/p", base: String = "base") async {
        store.point(at: folder, base: base)
        for _ in 0..<300 where store.panel == nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func oneNextPressSendsOnceAndTwoMoreSendNothing() async {
        let probe = SendProbe()
        let store = store(probe)
        await start(store)
        await store.press()
        #expect(probe.lines.count == 1)
        #expect(store.message?.contains("cad-execute-p1") == true)
        await store.press()
        await store.press()
        #expect(probe.lines.count == 1)
    }

    @Test func aHeldRowEndsThePendingState() async {
        let probe = SendProbe()
        let store = store(probe)
        await start(store)
        await store.press()
        store.setRows([row("cad-execute-p1", "running")])
        store.setRows([row("cad-execute-p1", "dead")])
        for _ in 0..<300 where store.panel?.button != .enabled { try? await Task.sleep(for: .milliseconds(10)) }
        await store.press()
        #expect(probe.lines.count == 2)
    }

    @Test func nextButtonIsOffWhilePendingAndReturnsWithTheHeldRow() async {
        let probe = SendProbe()
        let store = store(probe)
        await start(store)
        #expect(store.panel?.button == .enabled)
        await store.press()
        #expect(store.panel?.button == .off("Sent the line for cad-execute-p1. Waiting for the worker."))
        #expect(store.message?.hasPrefix("Sent the line for cad-execute-p1") == true)
        store.setRows([row("cad-execute-p1", "running")])
        store.setRows([row("cad-execute-p1", "dead")])
        for _ in 0..<300 where store.panel?.button != .enabled { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.panel?.button == .enabled)
    }

    @Test func aFailedDeliveryLeavesNothingPending() async {
        let probe = SendProbe()
        probe.fail = true
        let store = store(probe)
        await start(store)
        await store.press()
        #expect(probe.lines.isEmpty)
        probe.fail = false
        await store.press()
        #expect(probe.lines.count == 1)
    }

    @Test func chipsAreGuardedAndThePendingStateEndsAfterTheTimeout() async {
        let probe = SendProbe()
        let store = store(probe)
        await start(store)
        await store.pressChip(chip)
        await store.pressChip(chip)
        #expect(probe.lines.count == 1)
        #expect(store.message?.contains("already sent") == true)
        clock.date = clock.date.addingTimeInterval(61)
        await store.pressChip(chip)
        #expect(probe.lines.count == 2)
    }

    @Test func pointingAtAnotherProjectDropsThePendingState() async {
        let probe = SendProbe()
        let store = store(probe)
        await start(store)
        await store.press()
        await start(store, folder: "/q", base: "other")
        await store.press()
        #expect(probe.lines.count == 2)
    }
}
