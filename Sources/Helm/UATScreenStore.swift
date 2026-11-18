import Foundation

/// What the UAT screen shows: which copy of UAT.md was read, Cadence's own status for it, and the parsed items.
struct UATScreenData: Equatable {
    enum Source: Equatable { case none, worktree, project }
    var source: Source = .none
    var status: UATStatus.Outcome = .notStarted
    var file: UATFile.Outcome?
    /// The UAT.md that was read, nil when there is none.
    var path: String?
}

/// Reads exactly one UAT.md and runs `uat status` for it; never writes. `read` and `status` are injectable so a test
/// sees every open and every run.
struct UATScreenLoader {
    var read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    var status: (_ folder: String, _ phase: String) -> UATStatus.Outcome = { folder, phase in
        switch CadenceLocator.locate() {
        case .success(let scripts): return UATStatus.run(scripts, folder: folder, phase: phase)
        case .failure(let failure): return .unreadable(failure.reason)
        }
    }

    /// Worktree file when it exists, else the project copy, else not started. The phase text is checked first.
    func load(project: String, phase: String, worktree: String?) -> UATScreenData {
        guard UATStatus.isValidPhase(phase) else { return UATScreenData() }
        let relative = "/.planning/phases/\(phase)/UAT.md"
        if let wt = Self.insideWorktree(worktree, project: project) {
            let file = wt + relative
            // A symlink that leaves the worktree is not read, and `uat status` is not run for it.
            if FileManager.default.fileExists(atPath: file),
               URL(fileURLWithPath: file).resolvingSymlinksInPath().path.hasPrefix(wt + "/"),
               let text = read(file) {
                return UATScreenData(source: .worktree, status: status(wt, phase), file: UATFile.parse(text), path: file)
            }
        }
        let file = project + relative
        guard FileManager.default.fileExists(atPath: file), let text = read(file) else { return UATScreenData() }
        return UATScreenData(source: .project, status: status(project, phase), file: UATFile.parse(text), path: file)
    }

    /// The worktree's real path when it still exists and sits inside `<project>/.claude/worktrees/`.
    static func insideWorktree(_ path: String?, project: String) -> String? {
        guard let path else { return nil }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let base = URL(fileURLWithPath: project + "/.claude/worktrees").resolvingSymlinksInPath().path + "/"
        var isDir: ObjCBool = false
        guard real.hasPrefix(base), FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return nil }
        return real
    }

    /// `<worktree>/.planning/phases/<N>` for the UAT.md watch, only when it exists and the phase text is plain.
    static func watchFolder(project: String, phase: String, worktree: String?) -> String? {
        guard UATStatus.isValidPhase(phase), let wt = insideWorktree(worktree, project: project) else { return nil }
        let folder = wt + "/.planning/phases/\(phase)"
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue ? folder : nil
    }
}

/// The UAT screen's data. No timer: a load runs on `point`, on a change in the project's `.planning/` and on a change
/// to the worktree's UAT.md while the worktree exists. Each result is compared before it is published.
@MainActor
final class UATScreenStore: ObservableObject {
    @Published private(set) var data = UATScreenData()

    private let loader: UATScreenLoader
    private let queue = DispatchQueue(label: "UATScreenStore.read")
    private var project: String?
    private var phase = ""
    private var worktree: String?
    private var watchers: [ProjectWatcher] = []
    private var generation = 0

    /// The outcome of the last send: sent, refused or failed with the reason. The note text is never kept.
    @Published private(set) var outcome: InboxDelivery.Outcome?
    /// What the last sent result reads back as in UAT.md. Evaluated on each reload, never on a timer.
    @Published private(set) var readback: (item: Int, state: UATResult.Readback)?
    private var expecting: (item: Int, kind: UATResult.Kind)?
    private var sending = false
    private let deliver: @Sendable (String, String) -> InboxDelivery.Outcome

    init(loader: UATScreenLoader = UATScreenLoader(),
         deliver: @escaping @Sendable (String, String) -> InboxDelivery.Outcome = { InboxDelivery.append($0, inbox: $1) }) {
        self.loader = loader
        self.deliver = deliver
    }

    /// Why the result controls are off, nil when the worker is running and live and has an inbox.
    nonisolated static func controlsOff(state: WorkflowOverlay.State?, live: Bool, inbox: String?) -> String? {
        switch state {
        case nil: return "worker not running"
        case .waitingForMerge: return "waiting for merge"
        case .dead: return "worker ended"
        case .running:
            if !live { return "starting" }
            return inbox == nil ? "worker has no inbox" : nil
        }
    }

    /// Builds the fixed line and appends it to the verify worker's inbox off the main actor. Delivers nothing when the
    /// line is refused, the worker is not running and live, or a send is in flight. The returned task is for tests.
    @discardableResult
    func send(item: String, kind: UATResult.Kind, text: String?, firstPending: Int?,
              state: WorkflowOverlay.State?, live: Bool, inbox: String?) -> Task<Void, Never>? {
        guard !sending else { return nil }
        if let why = Self.controlsOff(state: state, live: live, inbox: inbox) {
            outcome = .refused(why)
            return nil
        }
        switch UATResult.build(item: item, kind: kind, text: text, firstPending: firstPending) {
        case .refused(let why):
            outcome = .refused(why)
            return nil
        case .line(let line):
            guard let inbox, let k = Int(item) else { return nil }
            sending = true
            let deliver = deliver
            return Task { [weak self] in
                let result = await Task.detached { deliver(line, inbox) }.value
                self?.sent(result, item: k, kind: kind)
            }
        }
    }

    private func sent(_ result: InboxDelivery.Outcome, item: Int, kind: UATResult.Kind) {
        sending = false
        outcome = result
        guard result == .sent else { return }
        expecting = (item, kind)
        readback = nil
        evaluate()
    }

    private func evaluate() {
        guard let expecting, case .items(let items)? = data.file else { return }
        let state = UATResult.readback(sent: expecting.kind, item: expecting.item, items: items)
        readback = (expecting.item, state)
        if case .recorded = state { self.expecting = nil }
    }

    /// Points the store at a project, a phase text and the phase's `cad-verify-p<N>` worker row's worktree, if any.
    func point(project: String?, phase: String, worktree: String?) {
        guard project != self.project || phase != self.phase || worktree != self.worktree else { return }
        self.project = project
        self.phase = phase
        self.worktree = worktree
        expecting = nil
        readback = nil
        outcome = nil
        let reload: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.reload() } }
        watchers = []
        if let project {
            watchers.append(ProjectWatcher(planningOf: project, onEvent: reload))
            if let folder = UATScreenLoader.watchFolder(project: project, phase: phase, worktree: worktree) {
                watchers.append(ProjectWatcher(uatIn: folder, onEvent: reload))
            }
        }
        reload()
    }

    func reload() {
        generation += 1
        let current = generation
        guard let project else {
            if data != UATScreenData() { data = UATScreenData() }
            return
        }
        let (phase, worktree, loader) = (phase, worktree, loader)
        queue.async { [weak self] in
            let result = loader.load(project: project, phase: phase, worktree: worktree)
            Task { @MainActor in self?.finish(result, generation: current) }
        }
    }

    private func finish(_ result: UATScreenData, generation done: Int) {
        guard done == generation, result != data else { return }
        data = result
        evaluate()
    }
}

/// The words the UAT screen draws, built from the store's values. The view only draws this.
/// Counts and result are Cadence's own (`uat status`), never recomputed from the items.
struct UATScreenText: Equatable {
    struct Row: Equatable {
        let number: Int
        let name: String
        let expected: String
        let status: String
        /// nil for the user's own answer; "verifier" or "model" otherwise.
        let source: String?
        let note: String?
        /// The `first_pending` row: the only one with result controls (D-01).
        var isCurrent = false
        /// "recorded as pass" or the mismatch text, under the row that was sent.
        var readback: String?
    }

    let header: String
    /// Which copy is shown, nil when there is none.
    let copyLine: String?
    let countsLine: String?
    let rows: [Row]
    /// "not started", an unreadable reason or the unsupported-version text.
    let message: String?
    /// Project-relative UAT.md path to draw as a link, only for an unsupported version.
    let rawFileLink: String?
    /// Why the current row's controls are off, nil when they work.
    var controlsOff: String?

    /// The card state of the phase's `cad-verify-p<N>` questions. Overlay none gives no card.
    static func cardState(phase: String, overlay: WorkflowOverlay?, live: Bool) -> ContextCardState.State {
        ContextCardState.state(label: WorkflowDispatch.label(stage: .verify, phase: phase), overlay: overlay?.state, live: live)
    }

    static func make(phase: String, data: UATScreenData, overlay: WorkflowOverlay?, live: Bool = false, inbox: String? = nil,
                     readback: (item: Int, state: UATResult.Readback)? = nil) -> UATScreenText {
        let header = "UAT: phase \(phase) - \(overlay?.text ?? "no worker")"
        guard data.source != .none else {
            return UATScreenText(header: header, copyLine: nil, countsLine: nil, rows: [], message: "not started", rawFileLink: nil)
        }
        let copy = data.source == .worktree ? "worktree copy (not merged yet)" : "project copy"
        var counts: String?
        var message: String?
        switch data.status {
        case .loaded(let s):
            let c = s.counts
            counts = "pass \(c.pass), fail \(c.fail), pending \(c.pending), skipped \(c.skipped), blocked \(c.blocked) - \(s.result)"
        case .notStarted: message = "not started"
        case .unreadable(let reason): message = reason
        }
        var rows: [Row] = []
        var link: String?
        var current: Int?
        if case .loaded(let s) = data.status { current = s.firstPending?.k }
        switch data.file {
        case .items(let items)?:
            rows = items.map { item in
                Row(number: item.k, name: item.name, expected: item.expected, status: item.status, source: item.source, note: item.note,
                    isCurrent: item.k == current, readback: readback?.item == item.k ? readback?.state.text : nil)
            }
        case .unsupported(let version)?:
            message = "UAT.md has fields_version \(version), which this app cannot show. Open the file instead."
            link = ".planning/phases/\(phase)/UAT.md"
        case nil: break
        }
        let off = current == nil ? nil : UATScreenStore.controlsOff(state: overlay?.state, live: live, inbox: inbox)
        return UATScreenText(header: header, copyLine: "Showing the \(copy)", countsLine: counts, rows: rows, message: message,
                             rawFileLink: link, controlsOff: off)
    }
}
