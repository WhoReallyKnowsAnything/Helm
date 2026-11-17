import Foundation

/// The selected project's gate holds (D-14). No timer: a read happens when the project changes and on every
/// hold file event, and each result is compared before it is published.
@MainActor
final class HoldStore: ObservableObject {
    /// Oldest first. Empty while no project is set or before its first read.
    @Published private(set) var holds: [GateHold] = []
    @Published private(set) var failure: String?

    /// Owns the reads: the folder, the files and `ps` never run on the main actor.
    private let queue = DispatchQueue(label: "HoldStore.read")
    private var project: String?
    /// Turns each hold file event into a read request. Released on re-point, which stops the stream.
    private var watcher: ProjectWatcher?
    /// Bumped on every re-point, so a read that finishes for the old project is dropped.
    private var generation = 0
    private var reading = false
    /// A request that arrived during a read. One more read runs after it, so no event is lost.
    private var readAgain = false

    typealias Decide = @Sendable (_ label: String, _ id: String, _ choice: HoldChoice, _ hash: String, _ folder: String) -> HoldDecision

    /// The seam (D-08): tests replace the decider in code.
    private let decider: Decide
    /// Runs the re-read and the decision, apart from `queue` so a slow decision never delays a read.
    private let deciderQueue = DispatchQueue(label: "HoldStore.decide")
    /// Per hold key, for the selected project only. Dropped when the key disappears or the project changes.
    @Published private var running: Set<String> = []
    @Published private var outcomes: [String: (text: String, final: Bool)] = [:]

    init(decider: @escaping Decide = { HoldDecider.decide(label: $0, id: $1, choice: $2, hash: $3, folder: $4) }) {
        self.decider = decider
    }

    /// Points the store at a project folder, or at nothing.
    func point(at folder: String?) {
        guard folder != project else { return }
        generation += 1
        reading = false
        readAgain = false
        project = folder
        if !running.isEmpty { running = [] }
        if !outcomes.isEmpty { outcomes = [:] }
        watcher = folder.map { ProjectWatcher(holdsOf: $0) { [weak self] in Task { @MainActor in self?.requestRead() } } }
        if !holds.isEmpty { holds = [] }
        if failure != nil { failure = nil }
        requestRead()
    }

    func requestRead() {
        guard let project else { return }
        if reading {
            readAgain = true
            return
        }
        reading = true
        let current = generation
        queue.async { [weak self] in
            let outcome = GateHoldReader.read(project: project)
            Task { @MainActor in self?.finish(outcome, generation: current) }
        }
    }

    private func finish(_ outcome: GateHoldRead, generation done: Int) {
        guard done == generation else { return }
        reading = false
        switch outcome {
        case .failed(let text):
            if failure != text { failure = text }
        case .holds(let list):
            if holds != list { holds = list }
            track(list)
            if failure != nil { failure = nil }
        }
        if readAgain {
            readAgain = false
            requestRead()
        }
    }

    /// Drops the state of keys that are gone.
    private func track(_ list: [GateHold]) {
        let keys = Set(list.map(\.key))
        let kept = outcomes.filter { keys.contains($0.key) }
        if kept.count != outcomes.count { outcomes = kept }
        if !running.isSubset(of: keys) { running.formIntersection(keys) }
    }

    /// What one hold card shows (D-06). Buttons show only for a live hold that was not answered.
    struct Card: Equatable {
        let command: String
        let stateLine: String?
        let outcome: String?
        let showsButtons: Bool
        /// Approve and Deny work.
        let enabled: Bool
    }

    func card(for hold: GateHold) -> Card {
        let outcome = outcomes[hold.key]
        let shows = hold.state == .live && outcome?.final != true
        let enabled = shows && !running.contains(hold.key)
        return Card(
            command: hold.command, stateLine: hold.stateLine, outcome: outcome?.text,
            showsButtons: shows, enabled: enabled)
    }

    /// Answers the hold a button was drawn with. It uses that exact `(label, id, hash)`, never "the current hold with this id".
    func decide(_ key: String, _ choice: HoldChoice) {
        guard let project, let hold = holds.first(where: { $0.key == key }) else { return }
        let state = card(for: hold)
        guard state.enabled else { return }
        running.insert(key)
        if outcomes[key] != nil { outcomes[key] = nil }
        let current = generation, decider = decider
        let (label, id, hash) = (hold.label, hold.id, hold.hash)
        deciderQueue.async { [weak self] in
            let result = Self.attempt(project: project, label: label, id: id, choice: choice, hash: hash, decider: decider)
            Task { @MainActor in self?.finishDecision(key, result, generation: current) }
        }
    }

    /// The re-read right before the decision (D-05), then the decision. Runs off the main actor.
    nonisolated static func attempt(
        project: String, label: String, id: String, choice: HoldChoice, hash: String, decider: Decide
    ) -> HoldAttempt {
        guard let fresh = GateHoldReader.readHold(project: project, id: id) else { return .gone }
        if fresh.state == .decided { return .decided }
        if fresh.hash != hash || fresh.label != label { return .stale("the hold changed") }
        if fresh.state != .live { return .stale(fresh.stateLine ?? "the hold changed") }
        return .ran(decider(label, id, choice, hash, project))
    }

    private func finishDecision(_ key: String, _ result: HoldAttempt, generation done: Int) {
        // A hold that vanished meanwhile has no card left, and `track` already dropped its state.
        guard done == generation, holds.contains(where: { $0.key == key }) else { return }
        running.remove(key)
        outcomes[key] = result.outcome
    }
}

/// How one click ended before or after the decider ran.
enum HoldAttempt: Equatable {
    /// The files are gone.
    case gone
    case decided
    /// The hold is not the one that was drawn, or is no longer live. The text says why.
    case stale(String)
    case ran(HoldDecision)

    /// `final` removes the buttons. A failure keeps them, with its line shown.
    var outcome: (text: String, final: Bool) {
        switch self {
        case .gone, .ran(.alreadyDecided): ("already decided or ended", true)
        case .decided: ("decided", true)
        case .stale(let text): (text, true)
        case .ran(.delivered): ("decision sent", true)
        case .ran(.failed(let line)): (line, false)
        }
    }
}
