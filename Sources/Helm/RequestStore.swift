import Combine
import Foundation
import os

/// One AskUserQuestion request the app answered: its questions and the labels that were sent.
struct AnsweredQuestions: Equatable, Identifiable {
    let key: String
    let nodeKey: String
    let questions: [QuestionInput.Question]
    let picks: [String: [String]]
    var id: String { key }
}

/// The selected project's open permission requests (D-07). One `ControlLogStore` per session, file events only.
/// A request has no expiry (D-04). Modelled on `HoldStore`. Allow works at once (D-19).
@MainActor
final class RequestStore: ObservableObject {
    struct Session: Equatable {
        let nodeKey: String
        let outPath: String
        let inboxPath: String
        let live: Bool
        /// The folder of another open project, or "" for the selected one. Another project's requests only raise its sidebar badge.
        var project = ""
    }

    struct Entry: Equatable, Identifiable {
        let key: String
        let nodeKey: String
        let request: PermissionRequest
        let live: Bool
        var project = ""
        var id: String { key }
    }

    /// What one request card shows.
    struct Card: Equatable {
        let command: String
        let stateLine: String?
        let outcome: String?
        let showsButtons: Bool
        /// Allow and Deny work.
        let enabled: Bool
    }

    /// Per node in session order, oldest request first.
    @Published private(set) var entries: [Entry] = []
    /// Per node key: the model and interrupt state folded from the out log (D-09). Never written to disk (D-10).
    @Published private(set) var controls: [String: SessionControl] = [:]
    @Published private var running: Set<String> = []
    @Published private var picks: [String: [String: [String]]] = [:]
    /// Questions already answered from the app, in memory only (lost on quit, accepted).
    @Published private var answered: [AnsweredQuestions] = []
    /// Per request key: the highlighted row. A question card walks its options in one flat list and starts at the first.
    /// A permission card has 0 for Allow and 1 for Deny, and no entry until the user moves or presses 1 or 2.
    @Published private var highlights: [String: Int] = [:]
    @Published private var outcomes: [String: (text: String, final: Bool)] = [:]

    private struct Follow {
        let store: ControlLogStore
        let session: Session
        let subscription: AnyCancellable
        let controlSubscription: AnyCancellable
    }
    private var follows: [String: Follow] = [:]
    private var order: [String] = []
    private var pendings: [String: [PermissionRequest]] = [:]
    /// Runs the re-read and the answer, off the main actor.
    private let answerQueue = DispatchQueue(label: "RequestStore.answer")
    /// One prompt box per session, kept here so a half-typed message and dropped files survive a switch of session. In memory only.
    private var boxes: [String: PromptBoxModel] = [:]

    /// Most recent first. A store holds a whole chat, so only a few are kept; a click on a kept path does not re-read the log.
    private var conversations: [ConversationStore] = []
    static let keptConversations = 3

    /// The conversation store for an out log, reused across node clicks.
    func conversationStore(for path: String) -> ConversationStore {
        if let at = conversations.firstIndex(where: { $0.path == path }) {
            let kept = conversations.remove(at: at)
            conversations.insert(kept, at: 0)
            return kept
        }
        let store = ConversationStore(path: path)
        conversations.insert(store, at: 0)
        if conversations.count > Self.keptConversations { conversations.removeLast(conversations.count - Self.keptConversations) }
        return store
    }

    /// The session's prompt box, kept by its inbox path (the node key repeats across projects). With no inbox path the node key is used; an empty key gets a fresh box.
    func box(for nodeKey: String, inboxPath: String?) -> PromptBoxModel {
        let key = inboxPath ?? nodeKey
        if let kept = boxes[key] { return kept }
        let model = ConversationHost.makeModel(inboxPath: inboxPath)
        if !key.isEmpty { boxes[key] = model }
        return model
    }

    /// Points the store at the project's sessions. A session with the same out log keeps its follower.
    func setSessions(_ sessions: [Session]) {
        var next: [String: Follow] = [:]
        for session in sessions {
            if let old = follows[session.nodeKey], old.session.outPath == session.outPath {
                next[session.nodeKey] = Follow(
                    store: old.store, session: session, subscription: old.subscription,
                    controlSubscription: old.controlSubscription)
                continue
            }
            let store = ControlLogStore(path: session.outPath)
            let key = session.nodeKey
            let subscription = store.$pending.sink { [weak self] list in
                MainActor.assumeIsolated { self?.update(key, list) }
            }
            let controlSubscription = store.$control.sink { [weak self] state in
                MainActor.assumeIsolated { self?.updateControl(key, state) }
            }
            next[key] = Follow(
                store: store, session: session, subscription: subscription, controlSubscription: controlSubscription)
        }
        follows = next
        if !Set(controls.keys).isSubset(of: next.keys) { controls = controls.filter { next[$0.key] != nil } }
        order = sessions.map(\.nodeKey)
        pendings = pendings.filter { next[$0.key] != nil }
        rebuild()
    }

    private func updateControl(_ nodeKey: String, _ state: SessionControl) {
        guard follows[nodeKey] != nil, controls[nodeKey] != state else { return }
        controls[nodeKey] = state
    }

    func control(for nodeKey: String) -> SessionControl { controls[nodeKey] ?? SessionControl() }

    /// Marks that node's interrupt as sending. Call before the interrupt line is appended.
    func noteInterrupt(nodeKey: String, id: String) {
        follows[nodeKey]?.store.noteInterrupt(id: id)
    }

    private func update(_ nodeKey: String, _ list: [PermissionRequest]) {
        guard follows[nodeKey] != nil, pendings[nodeKey] ?? [] != list else { return }
        pendings[nodeKey] = list
        rebuild()
    }

    private func rebuild() {
        var list: [Entry] = []
        for nodeKey in order {
            guard let follow = follows[nodeKey] else { continue }
            for request in pendings[nodeKey] ?? [] {
                list.append(Entry(key: "request:\(nodeKey):\(request.requestId)", nodeKey: nodeKey,
                                  request: request, live: follow.session.live, project: follow.session.project))
            }
        }
        if list != entries { entries = list }
        track(list)
    }

    /// Drops the state of keys that are gone.
    private func track(_ list: [Entry]) {
        let keys = Set(list.map(\.key))
        let kept = outcomes.filter { keys.contains($0.key) }
        if kept.count != outcomes.count { outcomes = kept }
        if !running.isSubset(of: keys) { running.formIntersection(keys) }
        if !Set(picks.keys).isSubset(of: keys) { picks = picks.filter { keys.contains($0.key) } }
        if !Set(highlights.keys).isSubset(of: keys) { highlights = highlights.filter { keys.contains($0.key) } }
    }

    func entries(for nodeKey: String) -> [Entry] { entries.filter { $0.nodeKey == nodeKey } }

    /// The selected project's requests, which the cards show.
    var currentEntries: [Entry] { entries.filter { $0.project.isEmpty } }

    /// Node keys of the selected project with a live pending AskUserQuestion. The board shows "question waiting" for them.
    var pendingQuestionLabels: Set<String> {
        Set(currentEntries.filter { $0.live && $0.request.toolName == "AskUserQuestion" }.map(\.nodeKey))
    }

    /// Open requests per other project folder, for the sidebar badge.
    var pendingByProject: [String: Int] {
        entries.reduce(into: [:]) { if !$1.project.isEmpty { $0[$1.project, default: 0] += 1 } }
    }

    func card(for entry: Entry) -> Card {
        let outcome = outcomes[entry.key]
        let shows = entry.live && outcome?.final != true
        let enabled = shows && !running.contains(entry.key)
        return Card(
            command: entry.request.text, stateLine: entry.live ? entry.request.reason : "session ended",
            outcome: outcome?.text, showsButtons: shows, enabled: enabled)
    }

    /// Where a deny came from. Logged with every deny so an unexpected one can be traced.
    enum DenySource: String { case declineButton, denyButton, returnKey, other }

    /// Receives one line per deny. The default writes to the unified log; a test swaps it.
    var denyLog: (String) -> Void = { Logger(subsystem: "Helm", category: "deny").notice("\($0, privacy: .public)") }

    /// Question cards whose Decline was clicked once and now waits for "Confirm Decline".
    @Published private var declineArmed: Set<String> = []
    private static let confirmWindow: UInt64 = 3_000_000_000

    func isDeclineArmed(_ key: String) -> Bool { declineArmed.contains(key) }

    /// First click arms Decline for a short time and denies nothing. A second click inside the window denies.
    func declineClicked(_ key: String) {
        guard declineArmed.contains(key) else {
            declineArmed.insert(key)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.confirmWindow)
                self?.declineArmed.remove(key)
            }
            return
        }
        declineArmed.remove(key)
        answer(key, allow: false, source: .declineButton)
    }

    /// Answers the request a button was drawn with, into that node's own inbox only. Every deny logs its source.
    func answer(_ key: String, allow: Bool, source: DenySource = .other) {
        guard let entry = entries.first(where: { $0.key == key }), let follow = follows[entry.nodeKey] else { return }
        let state = card(for: entry)
        guard state.enabled else { return }
        if !allow { denyLog("deny request=\(entry.request.requestId) session=\(entry.nodeKey) source=\(source.rawValue)") }
        running.insert(key)
        if outcomes[key] != nil { outcomes[key] = nil }
        let request = entry.request, session = follow.session
        answerQueue.async { [weak self] in
            let result = Self.attempt(request: request, allow: allow, outPath: session.outPath, inbox: session.inboxPath)
            Task { @MainActor in self?.finish(key, result) }
        }
    }

    /// Changes whenever anything a card draws changes. The cards take it as an input: without one, SwiftUI sees equal
    /// inputs (same entries, same closures) and skips their bodies, so a mounted card never redraws (UAT 5 to 7).
    var stamp: Int {
        var hasher = Hasher()
        hasher.combine(running)
        hasher.combine(picks)
        hasher.combine(highlights)
        hasher.combine(declineArmed)
        for (key, value) in outcomes.sorted(by: { $0.key < $1.key }) { hasher.combine(key); hasher.combine(value.text); hasher.combine(value.final) }
        return hasher.finalize()
    }

    /// The AskUserQuestion labels picked so far per question text, in pick order.
    func picks(for key: String) -> [String: [String]] { picks[key] ?? [:] }

    /// The questions of an AskUserQuestion request. Empty for any other tool and for input that cannot be answered as a card.
    func questions(for entry: Entry) -> [QuestionInput.Question] {
        entry.request.toolName == "AskUserQuestion" ? QuestionInput.decode(entry.request.input) : []
    }

    /// A single-select pick replaces the earlier one, a multi-select pick toggles. Unknown keys, questions and labels are ignored.
    func pick(_ key: String, question: String, label: String) {
        guard let entry = entries.first(where: { $0.key == key }),
              let item = questions(for: entry).first(where: { $0.text == question }),
              item.options.contains(where: { $0.label == label }) else { return }
        var current = picks[key] ?? [:]
        var chosen = current[question] ?? []
        if !item.multiSelect { chosen = [label] }
        else if let at = chosen.firstIndex(of: label) { chosen.remove(at: at) }
        else { chosen.append(label) }
        current[question] = chosen.isEmpty ? nil : chosen
        picks[key] = current
    }

    /// Typed text becomes the whole answer of one question, replacing any earlier pick. Empty text, unknown keys and questions are ignored.
    func typeAnswer(_ key: String, question: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let entry = entries.first(where: { $0.key == key }),
              questions(for: entry).contains(where: { $0.text == question }) else { return }
        var current = picks[key] ?? [:]
        current[question] = [trimmed]
        picks[key] = current
    }

    /// Send works: the card shows buttons, no send runs, and every question has a pick.
    func canSend(_ entry: Entry) -> Bool {
        let items = questions(for: entry)
        let chosen = picks[entry.key] ?? [:]
        return !items.isEmpty && card(for: entry).enabled && items.allSatisfy { !(chosen[$0.text] ?? []).isEmpty }
    }

    /// A key press a card hands to the store. Escape is not handled here: it goes through the card's `onEscape` (D-08).
    struct KeyPress: Equatable {
        enum Key: Equatable { case up, down, enter, digit(Int), other }
        let key: Key
        /// Command, Control or Option held.
        var modified = false
    }

    /// The highlighted row of a request card, for drawing. Nil when nothing is highlighted.
    func highlight(for key: String) -> Int? {
        guard let entry = entries.first(where: { $0.key == key }) else { return nil }
        if entry.request.toolName == "AskUserQuestion" { return highlights[key] ?? 0 }
        return highlights[key]
    }

    /// Handles a key on a live, unanswered card. Returns false for every key it does not use, so the caller passes it on.
    /// Every answer goes through `answer` or `send`.
    func handle(_ press: KeyPress, for key: String) -> Bool {
        guard !press.modified, let entry = entries.first(where: { $0.key == key }) else { return false }
        let state = card(for: entry)
        guard state.showsButtons else { return false }
        let items = questions(for: entry)
        if items.isEmpty { return handlePermission(press, entry, state) }
        let flat = items.flatMap { q in q.options.map { (question: q, option: $0) } }
        guard !flat.isEmpty else { return false }
        let at = min(highlights[key] ?? 0, flat.count - 1)
        switch press.key {
        case .up: highlights[key] = max(at - 1, 0)
        case .down: highlights[key] = min(at + 1, flat.count - 1)
        case .digit(let n):
            let current = flat[at].question
            guard (1...9).contains(n), n <= current.options.count else { return false }
            pick(key, question: current.text, label: current.options[n - 1].label)
            if let row = flat.firstIndex(where: { $0.question.text == current.text && $0.option.label == current.options[n - 1].label }) {
                highlights[key] = row
            }
        case .enter:
            let target = flat[at]
            if picks[key]?[target.question.text]?.contains(target.option.label) == true { send(key) }
            else { pick(key, question: target.question.text, label: target.option.label) }
        case .other: return false
        }
        return true
    }

    private func handlePermission(_ press: KeyPress, _ entry: Entry, _ state: Card) -> Bool {
        switch press.key {
        case .up, .down: highlights[entry.key] = highlights[entry.key] == 0 ? 1 : 0
        case .digit(1): highlights[entry.key] = 0
        case .digit(2): highlights[entry.key] = 1
        case .enter: if let row = highlights[entry.key] { answer(entry.key, allow: row == 0, source: .returnKey) }
        case .digit, .other: return false
        }
        return true
    }

    /// The same interrupt the prompt box sends, into that node's own inbox only.
    func interrupt(nodeKey: String) {
        guard let inbox = follows[nodeKey]?.session.inboxPath else { return }
        let id = "app-" + UUID().uuidString
        noteInterrupt(nodeKey: nodeKey, id: id)
        answerQueue.async { _ = ControlLineWriter.appendInterrupt(id: id, inbox: inbox) }
    }

    /// Sends the picks of the request a button was drawn with, into that node's own inbox only.
    func send(_ key: String) {
        guard let entry = entries.first(where: { $0.key == key }), let follow = follows[entry.nodeKey], canSend(entry) else { return }
        running.insert(key)
        if outcomes[key] != nil { outcomes[key] = nil }
        let request = entry.request, session = follow.session, chosen = picks[key] ?? [:]
        answerQueue.async { [weak self] in
            let result = Self.attempt(request: request, outPath: session.outPath) {
                ControlAnswerWriter.appendAnswers(request, picks: chosen, inbox: session.inboxPath)
            }
            Task { @MainActor in self?.completeSend(key, nodeKey: entry.nodeKey, request: request, picks: chosen, result) }
        }
    }

    /// Records a sent answer BEFORE `finish`: `finish` returns early once the out-log tool result dropped the entry.
    func completeSend(_ key: String, nodeKey: String, request: PermissionRequest, picks chosen: [String: [String]], _ result: (text: String, final: Bool)) {
        if result.text == "decision sent" {
            answered.append(AnsweredQuestions(key: key, nodeKey: nodeKey, questions: QuestionInput.decode(request.input), picks: chosen))
        }
        finish(key, result)
    }

    /// The answered cards of one node, newest last.
    func answered(for nodeKey: String) -> [AnsweredQuestions] { answered.filter { $0.nodeKey == nodeKey } }

    /// The re-read from byte 0 right before the answer, then the answer. Runs off the main actor.
    nonisolated static func attempt(
        request: PermissionRequest, allow: Bool, outPath: String, inbox: String
    ) -> (text: String, final: Bool) {
        attempt(request: request, outPath: outPath) { ControlAnswerWriter.append(request, allow: allow, inbox: inbox) }
    }

    nonisolated static func attempt(
        request: PermissionRequest, outPath: String, write: () -> InboxDelivery.Outcome
    ) -> (text: String, final: Bool) {
        var fold = ControlRequests()
        fold.feed(OutLogReader(path: outPath).read().lines)
        guard fold.pending.contains(request) else { return ("already decided or ended", true) }
        switch write() {
        case .sent: return ("decision sent", true)
        case .refused(let line), .failed(let line): return (line, false)
        }
    }

    private func finish(_ key: String, _ result: (text: String, final: Bool)) {
        // A request that vanished meanwhile has no card left, and `track` already dropped its state.
        guard entries.contains(where: { $0.key == key }) else { return }
        running.remove(key)
        outcomes[key] = result
    }
}
