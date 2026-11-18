import Foundation

struct PlanReviewPlan: Equatable {
    var name: String
    var parsed: ParsedPlan
}

/// What the plan review screen shows. `root` says which checkout the plan files came from (D-06).
struct PlanReviewData: Equatable {
    enum Root: Equatable { case none, worktree, project }
    var root: Root = .none
    var waves: [[PlanReviewPlan]] = []
    /// A check for `REVIEW-plan.md` or `REVIEW-plan-*.md` under `phases/<N>/records/`; the file is never parsed.
    var reviewExists = false
    var reviewPath = ""
    var criteria: [String] = []

    var hasPlanFiles: Bool { !waves.isEmpty }
}

/// Reads only `PLAN.md` and `PLAN-<k>.md` from the chosen root, and looks for a plan review under `phases/<N>/records/` without reading it, and CONTEXT.md from the project (AC7).
/// Never writes. `read` and `runner` are injectable so a test sees every open and every process.
struct PlanReviewLoader {
    typealias Runner = (_ root: String, _ phase: String) -> ProcessResult

    var read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    var runner: Runner = PlanReviewLoader.liveRunner

    private static let timeoutSeconds: TimeInterval = 20

    static let liveRunner: Runner = { root, phase in
        guard case .success(let scripts) = CadenceLocator.locate() else {
            return ProcessResult(status: -1, stdout: "", stderr: "", startError: "Cadence scripts not found")
        }
        return ProcessRunner.run(
            scripts.node, [scripts.planning, "plan-overlap", "--phase", phase],
            environment: ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory()],
            workingFolder: root, timeout: timeoutSeconds)
    }

    static func isPhaseText(_ text: String) -> Bool {
        text.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// The worktree's real path when it still exists and sits inside `<project>/.claude/worktrees/`, else the project folder.
    func chooseRoot(project: String, worktree: String?) -> (path: String, root: PlanReviewData.Root) {
        if let worktree {
            let real = URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path
            let base = URL(fileURLWithPath: project + "/.claude/worktrees").resolvingSymlinksInPath().path + "/"
            var isDir: ObjCBool = false
            if real.hasPrefix(base), FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue {
                return (real, .worktree)
            }
        }
        return (project, .project)
    }

    /// The `waves` of `plan-overlap` run in `root`; empty on `ok:false`, a failed run or a bad phase text. Names are filtered.
    func planWaves(root: String, phase: String) -> [[String]] {
        guard Self.isPhaseText(phase) else { return [] }
        let result = runner(root, phase)
        guard !result.failedToStart, !result.timedOut,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true, let waves = json["waves"] as? [[String]] else { return [] }
        return waves.map { $0.filter { $0.range(of: #"^PLAN(-[0-9]+)?\.md$"#, options: .regularExpression) != nil } }
            .filter { !$0.isEmpty }
    }

    func load(project: String, phase: String, worktree: String?) -> PlanReviewData {
        guard Self.isPhaseText(phase) else { return PlanReviewData() }
        let (root, kind) = chooseRoot(project: project, worktree: worktree)
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let dir = "\(root)/.planning/phases/\(phase)"
        func inside(_ file: String) -> Bool {
            FileManager.default.fileExists(atPath: file)
                && URL(fileURLWithPath: file).resolvingSymlinksInPath().path.hasPrefix(realRoot + "/")
        }
        let waves: [[PlanReviewPlan]] = planWaves(root: root, phase: phase).map { names in
            names.compactMap { name in
                guard inside("\(dir)/\(name)"), let text = read("\(dir)/\(name)") else { return nil }
                return PlanReviewPlan(name: name, parsed: PlanReviewParser.parse(text))
            }
        }.filter { !$0.isEmpty }
        let criteria = read("\(project)/.planning/phases/\(phase)/CONTEXT.md").map(ContextCriteria.parse) ?? []
        let review = newestPlanReview(in: "\(dir)/records", inside: inside)
        return PlanReviewData(
            root: kind, waves: waves, reviewExists: review != nil,
            reviewPath: review.map { ".planning/phases/\(phase)/records/\($0)" } ?? "", criteria: criteria)
    }

    /// Name of the newest `REVIEW-plan.md` or `REVIEW-plan-*.md` in `folder` by modification date (name breaks a tie); nil when none.
    /// Never reads a file. A risk_surface, diff or phase_diff review does not match.
    private func newestPlanReview(in folder: String, inside: (String) -> Bool) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let found: [(name: String, date: Date)] = names.compactMap { name in
            guard name == "REVIEW-plan.md" || (name.hasPrefix("REVIEW-plan-") && name.hasSuffix(".md")),
                  inside("\(folder)/\(name)") else { return nil }
            let date = (try? FileManager.default.attributesOfItem(atPath: "\(folder)/\(name)")[.modificationDate] as? Date) ?? .distantPast
            return (name, date)
        }
        return found.max { ($0.date, $0.name) < ($1.date, $1.name) }?.name
    }
}

/// The plan review screen's data. No timer: a load runs on `point` and on a change under the root's `.planning/`.
/// Each result is compared before it is published, so a `trace.jsonl` write causes no redraw.
@MainActor
final class PlanReviewStore: ObservableObject {
    @Published private(set) var data = PlanReviewData()

    private let loader: PlanReviewLoader
    private let queue = DispatchQueue(label: "PlanReviewStore.read")
    private var project: String?
    private var phase = ""
    private var worktree: String?
    private var watchers: [ProjectWatcher] = []
    private var generation = 0

    init(loader: PlanReviewLoader = PlanReviewLoader()) {
        self.loader = loader
    }

    /// Points the store at a project, a phase text and the `cad-plan-p<N>` worker row's worktree, if any. Call again on a row change.
    func point(project: String?, phase: String, worktree: String?) {
        guard project != self.project || phase != self.phase || worktree != self.worktree else { return }
        self.project = project
        self.phase = phase
        self.worktree = worktree
        let reload: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.reload() } }
        watchers = []
        if let project {
            let root = loader.chooseRoot(project: project, worktree: worktree).path
            if root == project {
                watchers.append(ProjectWatcher(planningOf: project, onEvent: reload))
            } else {
                // The worktree's .planning may not exist yet, so watch the worktree folder; the project's CONTEXT.md is read once per load.
                watchers.append(ProjectWatcher(folder: root, onEvent: reload))
            }
        }
        reload()
    }

    func reload() {
        generation += 1
        let current = generation
        guard let project else {
            if data != PlanReviewData() { data = PlanReviewData() }
            return
        }
        let (phase, worktree, loader) = (phase, worktree, loader)
        queue.async { [weak self] in
            let result = loader.load(project: project, phase: phase, worktree: worktree)
            Task { @MainActor in self?.finish(result, generation: current) }
        }
    }

    private func finish(_ result: PlanReviewData, generation done: Int) {
        guard done == generation, result != data else { return }
        data = result
    }
}
