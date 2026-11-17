import Foundation

/// What the context screen shows: earlier phases' decisions (project folder, D-04) and this phase's (D-05).
struct ContextScreenData: Equatable {
    enum Source: Equatable { case none, worktree, project }
    var earlier: [ContextDecision] = []
    var current: [ContextDecision] = []
    var source: Source = .none
}

/// Reads at most 4 CONTEXT.md files, never writes (D-04, D-05). `read` is injectable so a test sees every open.
struct ContextScreenLoader {
    var read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }

    func load(project: String, phase: String, worktree: String?) -> ContextScreenData {
        guard ContextDecisions.isPhaseText(phase) else { return ContextScreenData() }
        let fm = FileManager.default
        let phasesDir = project + "/.planning/phases"
        func file(_ root: String, _ p: String) -> String { "\(root)/.planning/phases/\(p)/CONTEXT.md" }
        let folders = (try? fm.contentsOfDirectory(atPath: phasesDir)) ?? []
        let earlier = ContextDecisions.earlierPhases(folders: folders, current: phase) { fm.fileExists(atPath: file(project, $0)) }
            .flatMap { p in read(file(project, p)).map { ContextDecisions.parse($0, phase: p) } ?? [] }

        if let wt = insideWorktree(worktree, project: project), let text = readInside(file(wt, phase), root: wt) {
            return ContextScreenData(earlier: earlier, current: ContextDecisions.parse(text, phase: phase), source: .worktree)
        }
        guard fm.fileExists(atPath: file(project, phase)), let text = read(file(project, phase)) else {
            return ContextScreenData(earlier: earlier)
        }
        return ContextScreenData(earlier: earlier, current: ContextDecisions.parse(text, phase: phase), source: .project)
    }

    /// The worktree's real path when it still exists and sits inside `<project>/.claude/worktrees/`.
    private func insideWorktree(_ path: String?, project: String) -> String? {
        guard let path else { return nil }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let base = URL(fileURLWithPath: project + "/.claude/worktrees").resolvingSymlinksInPath().path + "/"
        var isDir: ObjCBool = false
        guard real.hasPrefix(base), FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return nil }
        return real
    }

    /// Reads `file` only when it exists and its real path stays inside `root` (a symlink out is not read).
    private func readInside(_ file: String, root: String) -> String? {
        guard FileManager.default.fileExists(atPath: file),
              URL(fileURLWithPath: file).resolvingSymlinksInPath().path.hasPrefix(root + "/") else { return nil }
        return read(file)
    }
}

/// The context screen's data (CTX-01). No timer: a load runs on `point`, and on a change in the project's
/// `.planning/` or in the worktree while it exists. Each result is compared before it is published.
@MainActor
final class ContextScreenStore: ObservableObject {
    @Published private(set) var data = ContextScreenData()

    private let loader: ContextScreenLoader
    private let queue = DispatchQueue(label: "ContextScreenStore.read")
    private var project: String?
    private var phase = ""
    private var worktree: String?
    private var watchers: [ProjectWatcher] = []
    private var generation = 0

    init(loader: ContextScreenLoader = ContextScreenLoader()) {
        self.loader = loader
    }

    /// Points the store at a project, a phase text and the phase's `cad-context-p<N>` worker row's worktree, if any.
    func point(project: String?, phase: String, worktree: String?) {
        guard project != self.project || phase != self.phase || worktree != self.worktree else { return }
        self.project = project
        self.phase = phase
        self.worktree = worktree
        let reload: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.reload() } }
        watchers = []
        if let project {
            watchers.append(ProjectWatcher(planningOf: project, onEvent: reload))
            if let worktree, FileManager.default.fileExists(atPath: worktree) {
                watchers.append(ProjectWatcher(folder: worktree, onEvent: reload))
            }
        }
        reload()
    }

    func reload() {
        generation += 1
        let current = generation
        guard let project else {
            if data != ContextScreenData() { data = ContextScreenData() }
            return
        }
        let (phase, worktree, loader) = (phase, worktree, loader)
        queue.async { [weak self] in
            let result = loader.load(project: project, phase: phase, worktree: worktree)
            Task { @MainActor in self?.finish(result, generation: current) }
        }
    }

    private func finish(_ result: ContextScreenData, generation done: Int) {
        guard done == generation, result != data else { return }
        data = result
    }
}

/// The words the context screen draws, built from the store's values. The view only draws this.
struct ContextScreenText: Equatable {
    struct Line: Equatable {
        /// `Phase M D-NN (area)`
        let title: String
        let text: String
    }

    struct Section: Equatable {
        let heading: String
        /// "not merged yet" for this phase's decisions read from the worktree.
        let note: String?
        let lines: [Line]
    }

    let header: String
    /// "worker ended" for a dead worker's card state.
    let endedLine: String?
    /// One line per answered question: the question text and the labels sent.
    let answered: [String]
    let sections: [Section]

    static func make(
        phase: String, data: ContextScreenData, overlay: WorkflowOverlay?, state: ContextCardState.State,
        answered: [AnsweredQuestions]
    ) -> ContextScreenText {
        func line(_ d: ContextDecision) -> Line { Line(title: "Phase \(d.phase) \(d.label) (\(d.area))", text: d.text) }
        var sections: [Section] = []
        var order: [String] = []
        for d in data.earlier where !order.contains(d.phase) { order.append(d.phase) }
        for p in order {
            sections.append(Section(heading: "Phase \(p)", note: nil, lines: data.earlier.filter { $0.phase == p }.map(line)))
        }
        if !data.current.isEmpty {
            sections.append(Section(
                heading: "Phase \(phase) (this phase)", note: data.source == .worktree ? "not merged yet" : nil,
                lines: data.current.map(line)))
        }
        return ContextScreenText(
            header: "Context: phase \(phase) - \(overlay?.text ?? "no worker")",
            endedLine: state == .workerEnded ? "worker ended" : nil,
            answered: answered.flatMap { a in
                a.questions.map { "\($0.display): \(a.picks[$0.text]?.joined(separator: ", ") ?? "")" }
            },
            sections: sections)
    }
}
