import SwiftUI

/// The milestone screen: the full audit verdict, each break with its next action. Read-only; the store runs the audit.
struct MilestoneScreenView: View {
    let project: String?
    let milestone: String
    /// The last phase number. It feeds the worker label only.
    let lastPhase: Int?
    /// The `cad-milestone-p<N>` row's worktree path, nil when it has none.
    var worktree: String?
    /// The milestone worker's state; a change reloads the audit.
    var workerState: WorkflowOverlay.State?
    /// Why Close and Override are off (no live orchestrator window), or nil.
    var chipsOff: String?
    /// True when the line was sent, so the reason field clears (D-09).
    var onClose: () async -> Bool = { false }
    var onOverride: (String) async -> Bool = { _ in false }
    var onLand: () async -> Bool = { false }
    @ObservedObject var requests: RequestStore
    /// The worker's window is live (not in `WorkflowStore.endedLabels`).
    var live = false
    var onClear: (String) -> Void = { _ in }

    @StateObject private var store = MilestoneScreenStore()
    @State private var reason = ""

    /// A line that can hold a file path: a link when a project is open (D-06), else plain text.
    @ViewBuilder private func linked(_ line: String) -> some View {
        if let project {
            FileLinkView(text: line, project: URL(fileURLWithPath: project), worktree: worktree.map { URL(fileURLWithPath: $0) })
        } else {
            Text(line)
        }
    }

    /// The reason the close controls are off, nil when they work.
    private var controlsOff: String? {
        if let chipsOff { return chipsOff }
        return workerState == nil ? nil : "The milestone worker \(label) is already held."
    }

    private var label: String {
        lastPhase.map { WorkflowDispatch.label(stage: .milestone, phase: String($0)) } ?? "cad-milestone"
    }

    private var cardState: ContextCardState.State { ContextCardState.state(label: label, overlay: workerState, live: live) }
    private var entries: [RequestStore.Entry] { requests.entries(for: label).filter { $0.project.isEmpty } }

    @ViewBuilder private var cards: some View {
        switch cardState {
        case .noCard:
            EmptyView()
        case .answerable:
            RequestCards(entries: entries, card: requests.card(for:), onAnswer: requests.answer,
                         question: QuestionBinding(requests), stamp: requests.stamp)
        case .workerEnded, .waitingForMerge, .starting:
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(entries) { entry in
                    if let card = ContextCardState.card(for: entry, state: cardState) {
                        KitHoldCard(stateLine: card.stateLine, outcome: card.outcome) {
                            HoldCommandText(text: card.command)
                        } decision: {
                            if ContextCardState.offersClear(cardState) {
                                Button { onClear(label) } label: { Text("Clear \(label)") }.buttonStyle(.kit)
                            }
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("\(milestone)  \(label)").kitType(.meta).foregroundStyle(Ink.textSecondary)
                let closed = store.land?.closed.isClosed == true
                let audit: MilestoneAudit? = { if case .success(let audit)? = store.result { return audit } else { return nil } }()
                let primary = Self.primary(audit: audit, controlsOff: controlsOff, landOff: landOff, closed: closed)
                KitStageActionRow(primaryTitle: primary.title, primaryReason: primary.off,
                                  onPrimary: { Task { _ = closed ? await onLand() : await onClose() } },
                                  secondary: { Button { store.refresh() } label: { Text("Refresh") }.buttonStyle(.kit) },
                                  menu: { EmptyView() })
                cards
                switch store.result {
                case nil:
                    Text("Reading the audit").kitType(.meta).foregroundStyle(Ink.textSecondary)
                case .failure(let failure)?:
                    Text(failure.reason).kitType(.meta).foregroundStyle(Ink.waiting)
                case .success(let audit)?:
                    verdict(audit)
                }
                landSection
            }
            .padding(Space.sm)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.point(project: project, worktree: worktree, label: label) }
        .onChange(of: project) { store.point(project: project, worktree: worktree, label: label) }
        .onChange(of: worktree) { store.point(project: project, worktree: worktree, label: label) }
        .onChange(of: workerState) { store.reload() }
    }

    @ViewBuilder private func verdict(_ audit: MilestoneAudit) -> some View {
        Text(audit.isFail ? "FAIL" : "PASS").kitType(.section)
            .foregroundStyle(audit.isFail ? Ink.toolFailed : Ink.text)
        ForEach(Self.failReasons(audit), id: \.self) { why in
            Text(why).kitType(.meta).foregroundStyle(Ink.text)
        }
        closeControls(audit)
        ForEach(Array(audit.breaks.enumerated()), id: \.offset) { _, item in
            VStack(alignment: .leading, spacing: Space.xs) {
                linked(Self.rowTitle(item)).kitType(.section).foregroundStyle(Ink.text)
                ForEach(MilestoneNextActions.lines(for: item.code), id: \.self) { line in
                    linked(line).kitType(.meta).foregroundStyle(Ink.textSecondary)
                }
            }
        }
        if let drift = audit.drift {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("version_drift: \(drift.docVersion) is already tagged as \(drift.publishedAs), cycle \(drift.cycleState)")
                    .kitType(.section).foregroundStyle(Ink.text)
                ForEach(MilestoneNextActions.lines(for: "version_drift"), id: \.self) { line in
                    Text(line).kitType(.meta).foregroundStyle(Ink.textSecondary)
                }
            }
        }
        if !audit.deferred.isEmpty {
            Text("Deferred, not counted: \(audit.deferred.joined(separator: ", "))")
                .kitType(.meta).foregroundStyle(Ink.textSecondary)
        }
    }

    /// The first reason Land is off, nil when it works: not closed, no live worker, then the orchestrator reason.
    private var landOff: String? {
        if store.land?.closed.isClosed != true { return "The cycle is not closed in the worker copy yet." }
        if workerState == nil || workerState == .dead { return "No live \(label) worker to land with." }
        return chipsOff
    }

    /// One line per fact; a reason string is a line too, never a blank.
    static func landLines(_ land: MilestoneLandState) -> [String] {
        func tag(_ name: String, _ answer: MilestoneLandTags.Answer?) -> String {
            switch answer {
            case nil: return "\(name) tag: reading"
            case .present(let found)?: return "\(name) tag: present (\(found))"
            case .absent?: return "\(name) tag: absent"
            case .unknown(let why)?: return "\(name) tag: \(why)"
            }
        }
        var lines: [String] = []
        switch land.facts {
        case .noWorktree: lines.append("Worker copy: no worktree")
        case .facts(let branch, let ahead, let dirty):
            lines.append("Branch: \(branch), \(ahead) ahead, \(dirty ? "dirty" : "clean")")
        case .failed(let why): lines.append("Worker copy: \(why)")
        }
        switch land.closed {
        case .closed: lines.append("Cycle: closed in the worker copy")
        case .open: lines.append("Cycle: still open in the worker copy")
        case .unreadable(let why): lines.append("Cycle: \(why)")
        }
        lines.append(tag("Local", land.localTag))
        lines.append(tag("Origin", land.originTag))
        return lines
    }

    static func pullRequestLine(_ state: PullRequestStore.State) -> String {
        switch state {
        case .unselected, .loading: return "Pull request: reading"
        case .loaded(nil): return "Pull request: no pull request"
        case .loaded(let pr?): return "Pull request: #\(pr.number) \(pr.state.lowercased())"
        case .failed(let why): return "Pull request: \(why)"
        }
    }

    @ViewBuilder private var landSection: some View {
        Text("Land").kitType(.section).foregroundStyle(Ink.text)
        if let land = store.land {
            ForEach(Self.landLines(land), id: \.self) { linked($0).kitType(.meta).foregroundStyle(Ink.textSecondary) }
        }
        if store.sentReason != nil {
            if let land = store.land, !land.captured.isEmpty {
                ForEach(land.captured, id: \.self) { Text("Captured: \($0)").kitType(.meta).foregroundStyle(Ink.textSecondary) }
            } else {
                Text("The worker has not captured the override reason yet in .planning/CAPTURE.md")
                    .kitType(.meta).foregroundStyle(Ink.textSecondary)
            }
        }
        PullRequestLine(store: store.pullRequests)
        if let off = landOff { Text(off).kitType(.meta).foregroundStyle(Ink.waiting) }
    }

    /// The one primary: Close until the cycle is closed in the worker copy, then Land. `off` is its reason, nil when it works.
    static func primary(audit: MilestoneAudit?, controlsOff: String?, landOff: String?, closed: Bool) -> (title: String, off: String?) {
        if closed { return ("Land", landOff) }
        if let controlsOff { return ("Close", controlsOff) }
        guard let audit else { return ("Close", "The audit is not loaded yet.") }
        if audit.isFail {
            return ("Close", (failReasons(audit) + ["an override needs a reason"]).joined(separator: ", "))
        }
        return ("Close", nil)
    }

    @ViewBuilder private func closeControls(_ audit: MilestoneAudit) -> some View {
        if let off = controlsOff { Text(off).kitType(.meta).foregroundStyle(Ink.waiting) }
        if audit.isFail {
            HStack(spacing: Space.sm) {
                TextField("Reason for the override", text: $reason).textFieldStyle(.roundedBorder)
                Button { Task { let typed = reason; if await onOverride(typed) { store.sent(reason: typed); reason = "" } } } label: { Text("Override") }
                    .buttonStyle(.kit)
                    .disabled(controlsOff != nil || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// One line per reason the verdict fails; empty on PASS.
    static func failReasons(_ audit: MilestoneAudit) -> [String] {
        var reasons: [String] = []
        if audit.counts.broken > 0 { reasons.append("\(audit.counts.broken) broken requirement(s)") }
        if !audit.coverageBreaks.isEmpty { reasons.append("\(audit.coverageBreaks.count) coverage break(s)") }
        if audit.drift != nil { reasons.append("version drift") }
        return reasons
    }

    static func rowTitle(_ item: MilestoneAudit.Break) -> String {
        [item.id, item.phase.map { "phase \($0)" }, item.code, item.file].compactMap { $0 }.joined(separator: "  ")
    }
}

/// Observes the screen's own pull request store, which the parent view does not see change.
private struct PullRequestLine: View {
    @ObservedObject var store: PullRequestStore

    var body: some View {
        Text(MilestoneScreenView.pullRequestLine(store.state)).kitType(.meta).foregroundStyle(Ink.textSecondary)
    }
}
