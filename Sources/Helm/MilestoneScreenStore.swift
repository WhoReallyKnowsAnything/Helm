import Foundation

/// What the land section shows. `originTag` is nil until the first origin call finishes.
struct MilestoneLandState: Equatable {
    var facts: MilestoneLandFacts
    var closed: MilestoneClosed.Answer
    var localTag: MilestoneLandTags.Answer
    var originTag: MilestoneLandTags.Answer?
    /// The CAPTURE.md bullets that hold the override reason the view sent; empty when none or not yet captured.
    var captured: [String] = []
}

/// The readers behind the land section, injectable so a test sees every call. Only `originTag` touches the network.
struct MilestoneLandReader: Sendable {
    var facts: @Sendable (_ project: String, _ worktree: String?) -> MilestoneLandFacts
    var version: @Sendable (_ project: String, _ worktree: String?) -> String?
    var localTag: @Sendable (_ version: String?, _ project: String) -> MilestoneLandTags.Answer
    var originTag: @Sendable (_ version: String?, _ project: String) -> MilestoneLandTags.Answer
    var closed: @Sendable (_ project: String, _ worktree: String?) -> MilestoneClosed.Answer
    var capture: @Sendable (_ project: String, _ worktree: String?, _ reason: String?) -> [String] = {
        MilestoneCapture.read(project: $0, worktree: $1, reason: $2)
    }

    static let live = MilestoneLandReader(
        facts: { MilestoneLandFacts.read(project: $0, worktree: $1) },
        version: { MilestoneLandTags.version(project: $0, worktree: $1) },
        localTag: { MilestoneLandTags.local(version: $0, project: $1) },
        originTag: { MilestoneLandTags.origin(version: $0, project: $1) },
        closed: { MilestoneClosed().read(project: $0, worktree: $1) })

    /// `fetchOrigin` false reuses `origin`, the last answer.
    func read(project: String, worktree: String?, origin: MilestoneLandTags.Answer?, fetchOrigin: Bool,
              reason: String? = nil) -> MilestoneLandState {
        let version = version(project, worktree)
        return MilestoneLandState(
            facts: facts(project, worktree), closed: closed(project, worktree),
            localTag: localTag(version, project),
            originTag: fetchOrigin ? originTag(version, project) : origin,
            captured: capture(project, worktree, reason))
    }
}

/// The last override reason sent per project, in memory for the app's lifetime, so a new screen store still reads CAPTURE.md back.
@MainActor
final class MilestoneSentReasons {
    static let shared = MilestoneSentReasons()
    private var byProject: [String: String] = [:]

    func reason(for project: String) -> String? { byProject[project] }
    func set(_ reason: String?, for project: String) { byProject[project] = reason }
}

/// The milestone screen's audit and land state. No timer: a load runs on `point`, on a change under the project's
/// `.planning/`, on a worker-state change the view reports and on Refresh (D-08). The origin and pull request calls run
/// only on `point` and Refresh. A stale result is dropped and an equal one is not published.
@MainActor
final class MilestoneScreenStore: ObservableObject {
    typealias Run = @Sendable (_ project: String) -> Result<MilestoneAudit, CadenceLocator.Failure>
    typealias PRFind = @Sendable (_ folder: String, _ label: String, _ worktree: String?) -> PullRequestLookupResult

    @Published private(set) var result: Result<MilestoneAudit, CadenceLocator.Failure>?
    @Published private(set) var land: MilestoneLandState?
    /// The cleaned reason the view sent, in memory only.
    @Published private(set) var sentReason: String?
    /// The screen's own store, so it never follows the worker selected elsewhere.
    let pullRequests = PullRequestStore()

    private let run: Run
    private let reader: MilestoneLandReader
    private let find: PRFind
    private var project: String?
    private var worktree: String?
    private var label: String?
    private let reasons: MilestoneSentReasons
    private var watcher: ProjectWatcher?
    private var worktreeWatcher: ProjectWatcher?
    private var generation = 0

    init(run: @escaping Run = { project in
        switch CadenceLocator.locate() {
        case .success(let scripts): return MilestoneAudit.run(scripts, project: project)
        case .failure(let failure): return .failure(failure)
        }
    }, land: MilestoneLandReader = .live,
         find: @escaping PRFind = { PullRequestLookup.find(folder: $0, label: $1, worktree: $2) },
         reasons: MilestoneSentReasons = .shared) {
        self.reasons = reasons
        self.run = run
        self.reader = land
        self.find = find
    }

    /// Points the store at a project, a worktree and a worker label. The same point again loads nothing. A new project
    /// or label reads origin and selects the pull request again; a new worktree path only reloads the local facts.
    func point(project: String?, worktree: String? = nil, label: String? = nil) {
        let moved = project != self.project || label != self.label
        guard moved || worktree != self.worktree else { return }
        let worktreeMoved = worktree != self.worktree
        self.worktree = worktree
        self.label = label
        let onChange: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.reload() } }
        if project != self.project {
            self.project = project
            sentReason = project.flatMap { reasons.reason(for: $0) }
            watcher = project.map { ProjectWatcher(planningOf: $0, onEvent: onChange) }
        }
        // The worker writes CAPTURE.md in its own worktree, which the project watcher excludes.
        if moved || worktreeMoved {
            worktreeWatcher = project.flatMap { UATScreenLoader.insideWorktree(worktree, project: $0) }
                .map { ProjectWatcher(planningOf: $0, onEvent: onChange) }
        }
        if moved { selectPullRequest() }
        reload(origin: moved)
    }

    /// A send of an override: remember the cleaned reason and read CAPTURE.md again (D-08).
    func sent(reason: String) {
        sentReason = MilestoneCapture.flatten(reason)
        if let project { reasons.set(sentReason, for: project) }
        reload()
    }

    /// The Refresh button: everything, origin and pull request included.
    func refresh() {
        pullRequests.refresh()
        reload(origin: true)
    }

    /// A worker-state change or a `.planning` change lands here. The cached origin answer is reused.
    @discardableResult
    func reload(origin fetchOrigin: Bool = false) -> Task<Void, Never>? {
        generation += 1
        let current = generation
        guard let project else {
            if result != nil { result = nil }
            if land != nil { land = nil }
            return nil
        }
        let run = run, reader = reader, worktree = worktree, cached = land?.originTag, reason = sentReason
        return Task { [weak self] in
            async let audit = Task.detached { run(project) }.value
            async let state = Task.detached {
                reader.read(project: project, worktree: worktree, origin: cached, fetchOrigin: fetchOrigin, reason: reason)
            }.value
            let (freshAudit, freshLand) = await (audit, state)
            self?.finish(freshAudit, generation: current)
            self?.finishLand(freshLand, generation: current)
        }
    }

    func finish(_ fresh: Result<MilestoneAudit, CadenceLocator.Failure>, generation done: Int) {
        guard done == generation, fresh != result else { return }
        result = fresh
    }

    func finishLand(_ fresh: MilestoneLandState, generation done: Int) {
        guard done == generation, fresh != land else { return }
        land = fresh
    }

    private func selectPullRequest() {
        guard let project, let label else { pullRequests.clear(); return }
        let find = find, worktree = worktree
        pullRequests.select(lookup: { find(project, label, worktree) })
    }

    var currentGeneration: Int { generation }
}
