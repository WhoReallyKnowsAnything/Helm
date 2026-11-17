import Foundation

/// What the execute screen shows: which root was read and, per plan in wave order, Cadence's status line plus the
/// light report read. Liveness is not stored here: the text builder applies it.
struct ExecuteScreenData: Equatable {
    enum Source: Equatable { case none, worktree, project }

    struct PlanData: Equatable {
        var file: String
        var k: Int
        var name: String?
        /// `replay-check`'s status line, nil when the plan has no report.
        var status: String?
        var report: ExecuteReport?
        /// The report's commit cells checked with git in the folder the report came from; nil without a report.
        var commits: ExecuteCommits.Outcome?
        /// The plan's task commits from the worktree's git log, oldest first; empty without a worktree copy.
        var gitRows: [ExecuteReport.Row] = []
    }

    enum Result: Equatable {
        case loaded(waves: [[PlanData]])
        /// The phase is not planned in the root that was read.
        case notPlanned
        case unreadable(String)
    }

    var source: Source = .none
    var result: Result = .notPlanned
}

/// Reads one phase's plans and reports; never writes. `run` and `readReport` are injectable so a test sees every run
/// and every opened path.
struct ExecuteScreenLoader {
    var run: (_ root: String, _ phase: String) -> ExecuteCadence.Outcome = { root, phase in
        switch CadenceLocator.locate() {
        case .success(let scripts): return ExecuteCadence.run(scripts, root: root, phase: phase)
        case .failure(let failure): return .unreadable(failure.reason)
        }
    }
    var readReport: (_ root: String, _ phase: String, _ k: Int) -> ExecuteReport? = ExecuteReport.read
    var liveCommits: (_ worktree: String, _ project: String) -> String = ExecuteCommits.liveLog

    /// The worktree when it is inside `<project>/.claude/worktrees/` and holds the phase folder, else the project (D-01, D-09).
    func load(project: String, phase: String, worktree: String?) -> ExecuteScreenData {
        guard UATStatus.isValidPhase(phase) else {
            return ExecuteScreenData(source: .none, result: .unreadable("Phase text is not a plain number."))
        }
        var root = project
        var source = ExecuteScreenData.Source.project
        if let wt = UATScreenLoader.insideWorktree(worktree, project: project) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: "\(wt)/.planning/phases/\(phase)", isDirectory: &isDir), isDir.boolValue {
                (root, source) = (wt, .worktree)
            }
        }
        switch run(root, phase) {
        case .noPhaseDir: return ExecuteScreenData(source: source, result: .notPlanned)
        case .unreadable(let reason): return ExecuteScreenData(source: source, result: .unreadable(reason))
        case .loaded(let plans, let waves):
            let log = source == .worktree ? liveCommits(root, project) : ""
            let data = plans.map { plan -> ExecuteScreenData.PlanData in
                let report = plan.exists ? readReport(root, phase, plan.k) : nil
                return ExecuteScreenData.PlanData(
                    file: plan.file, k: plan.k, name: plan.name, status: plan.status, report: report,
                    commits: report.map { ExecuteCommits.check(root: root, commits: $0.rows.map(\.commit)) },
                    gitRows: ExecuteCommits.liveRows(log: log, phase: phase, k: plan.k))
            }
            var ordered: [[ExecuteScreenData.PlanData]] = waves.map { wave in
                wave.compactMap { file in data.first { $0.file == file } }
            }
            // A plan that no wave names still shows, as its own last wave.
            let named = Set(waves.flatMap { $0 })
            let rest = data.filter { !named.contains($0.file) }
            if !rest.isEmpty { ordered.append(rest) }
            return ExecuteScreenData(source: source, result: .loaded(waves: ordered))
        }
    }
}

/// The execute screen's data. No timer: a load runs on `point` and on a change under the project's `.planning/`.
/// Each result is compared before it is published.
@MainActor
final class ExecuteScreenStore: ObservableObject {
    @Published private(set) var data = ExecuteScreenData()

    private let loader: ExecuteScreenLoader
    private let queue = DispatchQueue(label: "ExecuteScreenStore.read")
    private var project: String?
    private var phase = ""
    private var worktree: String?
    private var watcher: ProjectWatcher?
    private var reportsWatcher: ProjectWatcher?
    private var gitWatcher: ProjectWatcher?
    private var generation = 0

    init(loader: ExecuteScreenLoader = ExecuteScreenLoader()) { self.loader = loader }

    func point(project: String?, phase: String, worktree: String?) {
        guard project != self.project || phase != self.phase || worktree != self.worktree else { return }
        self.project = project
        self.phase = phase
        self.worktree = worktree
        let reload: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.reload() } }
        watcher = project.map { ProjectWatcher(planningOf: $0, onEvent: reload) }
        reportsWatcher = project.flatMap { project in
            UATScreenLoader.watchFolder(project: project, phase: phase, worktree: worktree)
                .map { ProjectWatcher(reportsIn: $0, onEvent: reload) }
        }
        gitWatcher = project.flatMap { UATScreenLoader.insideWorktree(worktree, project: $0) }
            .flatMap(ExecuteCommits.gitDir(ofWorktree:))
            .map { ProjectWatcher(gitLogIn: $0, onEvent: reload) }
        reload()
    }

    func reload() {
        generation += 1
        let current = generation
        guard let project else {
            if data != ExecuteScreenData() { data = ExecuteScreenData() }
            return
        }
        let (phase, worktree, loader) = (phase, worktree, loader)
        queue.async { [weak self] in
            let result = loader.load(project: project, phase: phase, worktree: worktree)
            Task { @MainActor in self?.finish(result, generation: current) }
        }
    }

    func finish(_ result: ExecuteScreenData, generation done: Int) {
        guard done == generation, result != data else { return }
        data = result
    }

    var currentGeneration: Int { generation }
}
