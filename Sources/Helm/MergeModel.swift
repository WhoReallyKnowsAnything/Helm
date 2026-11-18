import Foundation

/// What the merge sheet shows. Every step arrives as a closure, so tests use stubs and the blocking ones run
/// off the main actor. One run at a time: a second Confirm while a run goes starts nothing (D-04).
@MainActor
final class MergeModel: ObservableObject, Identifiable {
    /// `ContentView` presents the sheet with `.sheet(item:)`.
    let id = UUID()

    enum Verdict: Equatable { case merged, notMerged, failed }

    /// Everything the result view needs. It holds no reference to the worker's node: that node is gone once the
    /// row turns `merged` (D-03).
    struct Outcome: Equatable {
        var verdict: Verdict
        var status: Int32
        var output: String
        /// Why the verdict is not a plain one, e.g. a stopped run or a database that disagrees.
        var detail: String?
        /// The post-merge notice line, with whether it reached the orchestrator pane (D-07).
        var notice: String?
    }

    enum State: Equatable {
        case checking
        /// Nothing ran: the worker is not finished, or the database or environment could not be read.
        case refused(String)
        case preview(output: String, canConfirm: Bool)
        case running
        case result(Outcome)
    }

    @Published private(set) var state = State.checking

    let label: String
    private let title: String?
    private let readRow: @Sendable () -> WorkerRead
    private let captureEnvironment: @Sendable () throws -> [String: String]
    private let preview: @Sendable (_ environment: [String: String]) -> MergeReview.Run
    private let merge: @Sendable (_ environment: [String: String]) -> MergeReview.Run
    private let deliver: @Sendable (_ line: String) -> InboxDelivery.Outcome
    /// Fires once, right before the merge process starts, so the view can close the worker's terminal (D-11).
    private let willRun: @MainActor () -> Void
    /// D-05: a fresh pull request lookup that Confirm runs right before `--merge`, because the store's state can be
    /// stale. Nil keeps the plain Plan 2 flow.
    private let pullRequestCheck: (@Sendable () -> PullRequestLookupResult)?
    /// G3: a fresh UAT verdict that open and Confirm both run, because the UAT can turn partial in between. Nil keeps today's flow.
    private let uatGate: (@Sendable () -> UATGate.Verdict)?
    /// True only when the sheet was opened through "Merge locally anyway": a failed lookup then no longer refuses.
    let unknownPullRequestAllowed: Bool
    private var environment: [String: String] = [:]
    private var opened = false

    init(
        label: String, title: String?,
        readRow: @escaping @Sendable () -> WorkerRead,
        captureEnvironment: @escaping @Sendable () throws -> [String: String],
        preview: @escaping @Sendable ([String: String]) -> MergeReview.Run,
        merge: @escaping @Sendable ([String: String]) -> MergeReview.Run,
        deliver: @escaping @Sendable (String) -> InboxDelivery.Outcome,
        willRun: @escaping @MainActor () -> Void,
        pullRequestCheck: (@Sendable () -> PullRequestLookupResult)? = nil,
        unknownPullRequestAllowed: Bool = false,
        uatGate: (@Sendable () -> UATGate.Verdict)? = nil
    ) {
        self.uatGate = uatGate
        self.label = label
        self.title = title
        self.readRow = readRow
        self.captureEnvironment = captureEnvironment
        self.preview = preview
        self.merge = merge
        self.deliver = deliver
        self.willRun = willRun
        self.pullRequestCheck = pullRequestCheck
        self.unknownPullRequestAllowed = unknownPullRequestAllowed
    }

    /// The real steps for one worker: `folder` is the project's main checkout, `base` the orchestrator's session.
    convenience init(
        label: String, title: String?, folder: String, base: String, willRun: @escaping @MainActor () -> Void,
        pullRequestCheck: (@Sendable () -> PullRequestLookupResult)? = nil, unknownPullRequestAllowed: Bool = false,
        uatGate: (@Sendable () -> UATGate.Verdict)? = nil
    ) {
        self.init(
            label: label, title: title,
            readRow: {
                let database = WorkerDatabase(project: folder)
                defer { database.close() }
                return database.read()
            },
            captureEnvironment: { try MergeReview.environment() },
            preview: { MergeReview.preview(label: label, folder: folder, environment: $0) },
            merge: { MergeReview.merge(label: label, folder: folder, environment: $0) },
            deliver: { InboxDelivery.deliver($0, base: base) },
            willRun: willRun, pullRequestCheck: pullRequestCheck, unknownPullRequestAllowed: unknownPullRequestAllowed,
            uatGate: uatGate)
    }

    /// D-04: the orchestrator never writes `status='done'` (phase 2 D-05), so a finished worker is exactly this.
    nonisolated static func isFinished(_ row: WorkerRow) -> Bool {
        row.status == "running" && row.lastEvent == "done"
    }

    /// Reads the row, captures the environment once and runs the read-only preview. Runs nothing for a worker
    /// that is not finished. Safe to call twice: the second call does nothing.
    func open() async {
        guard !opened else { return }
        opened = true
        let readRow = self.readRow
        if let refusal = Self.refusal(for: await Task.detached(operation: { readRow() }).value, label: label) {
            state = .refused(refusal)
            return
        }
        if let why = await uatRefusal() {
            state = .refused(why)
            return
        }
        let capture = captureEnvironment
        switch await Task.detached(operation: { Result { try capture() } }).value {
        case .failure(let error): state = .refused(error.localizedDescription)
        case .success(let captured): environment = captured
        }
        guard case .checking = state else { return }
        let preview = self.preview, environment = self.environment
        let run = await Task.detached(operation: { preview(environment) }).value
        let ok = run.failure == nil && run.status == 0
        state = .preview(output: Self.text(of: run), canConfirm: ok)
    }

    /// Reads the row again, runs `--merge`, reads the row again, then sends the notice if it merged.
    func confirm() async {
        guard case .preview(_, canConfirm: true) = state else { return }
        state = .running
        let readRow = self.readRow
        if let refusal = Self.refusal(for: await Task.detached(operation: { readRow() }).value, label: label) {
            state = .refused(refusal)
            return
        }
        if let why = await uatRefusal() {
            state = .refused(why)
            return
        }
        if let check = pullRequestCheck {
            switch await Task.detached(operation: { check() }).value {
            case .found(let pullRequest) where pullRequest.isOpen:
                state = .refused("PR #\(pullRequest.number) is open. Ask the orchestrator to merge it.")
                return
            case .failed(let text) where !unknownPullRequestAllowed:
                state = .refused("pull request lookup failed: \(text)")
                return
            default: break
            }
        }
        willRun()
        let merge = self.merge, environment = self.environment
        let run = await Task.detached(operation: { merge(environment) }).value
        let after = await Task.detached(operation: { readRow() }).value
        var outcome = Self.outcome(label: label, run: run, rowAfter: after)
        if outcome.verdict == .merged { outcome.notice = await sendNotice() }
        state = .result(outcome)
    }

    /// The refusal text when G3 is closed (blocked or still checking), else nil. Runs off the main actor.
    private func uatRefusal() async -> String? {
        guard let gate = uatGate else { return nil }
        switch await Task.detached(operation: { gate() }).value {
        case .blocked(let reason): return "Merge is off: \(reason). Nothing was run."
        case .checking: return "Merge is off: checking UAT. Nothing was run."
        case .notGated, .confirmSkipped, .allowed: return nil
        }
    }

    // MARK: pure steps

    /// Why a run must not start, or nil when the row is the one D-04 allows.
    private static func refusal(for read: WorkerRead, label: String) -> String? {
        switch read {
        case .loaded(let state):
            guard let row = state.rows.first(where: { $0.agentId == label }) else {
                return "The worker \(label) is not in the project database. Nothing was run."
            }
            guard isFinished(row) else {
                return "The worker \(label) is not finished (status \(row.status), last event \(row.lastEvent ?? "none")). Nothing was run."
            }
            return nil
        case .noDatabase: return "The project has no worker database. Nothing was run."
        case .noState: return "The worker database has no sessions table. Nothing was run."
        case .permissionDenied: return "macOS does not let the app read the worker database. Nothing was run."
        case .failed(let reason): return "The worker database could not be read: \(reason). Nothing was run."
        }
    }

    private static func text(of run: MergeReview.Run) -> String {
        guard let failure = run.failure else { return run.output }
        return run.output.isEmpty ? failure.text : run.output + "\n" + failure.text
    }

    /// D-03: "merged" needs the classification and a fresh read that shows the row `merged`.
    private static func outcome(label: String, run: MergeReview.Run, rowAfter: WorkerRead) -> Outcome {
        let output = run.output, status = run.status
        if let failure = run.failure {
            return Outcome(verdict: .failed, status: status, output: output, detail: failure.text)
        }
        switch MergeReview.classifyMerge(label: label, status: status, output: output) {
        case .cancelled:
            return Outcome(verdict: .notMerged, status: status, output: output, detail: "The merge was cancelled.")
        case .failed:
            return Outcome(verdict: .failed, status: status, output: output)
        case .merged:
            guard case .loaded(let state) = rowAfter, state.rows.first(where: { $0.agentId == label })?.status == "merged" else {
                return Outcome(
                    verdict: .failed, status: status, output: output,
                    detail: "The output says merged but the project database does not show it.")
            }
            return Outcome(verdict: .merged, status: status, output: output)
        }
    }

    /// One line, once (D-07). The label and the title are untrusted text, so both are cleaned (D-10).
    private func sendNotice() async -> String {
        var line = "merge-review merged " + (InboxDelivery.clean(label) ?? label)
        if let title, let cleaned = InboxDelivery.clean(title) { line += " (task: \(cleaned))" }
        let deliver = self.deliver, sent = line
        switch await Task.detached(operation: { deliver(sent) }).value {
        case .sent: return "Notice sent: \(line)"
        case .refused(let reason), .failed(let reason): return "Notice not sent: \(reason)\n\(line)"
        }
    }
}
