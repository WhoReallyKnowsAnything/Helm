import AppKit
import SwiftUI

/// Which worker buttons are on (D-04, D-05, D-06). One pure decision, so a test pins it.
struct WorkerActions: Equatable {
    enum MergeKind: Equatable {
        /// The Plan 2 preview sheet.
        case local
        /// D-05: an open pull request is merged by the orchestrator, never by a local `--merge`.
        case askOrchestrator(number: Int)
    }

    var mergeEnabled = false
    /// Why Merge is off, or what it does.
    var mergeHelp = ""
    var mergeTitle = "Merge"
    var mergeKind = MergeKind.local
    /// "Merge locally anyway": the user's explicit choice after a failed lookup. It opens the preview sheet with a warning.
    var mergeAnywayEnabled = false
    var teardownEnabled = true
    /// The G3 Override button (D-09): hidden, off with a reason, or on.
    var overrideDisplay = UATOverride.Display.hidden
    /// Mark done: only for a worker that still runs and has not recorded `done`. The D-04 guard stays closed until it does.
    var markDoneShown = false
    /// Clear: only for an ended worker (its process is gone), as the stage screens offer it.
    var clearShown = false
    var clearLabel = ""
    /// The first line of the pull request strip.
    var summary = ""
    /// The second line: checks and the count of changed files. Nil without a pull request.
    var detail: String?

    /// `row` is a worker the tree draws. Merge is on only for a finished worker (D-04), and the pull request decides
    /// what the button does. Teardown is on for every drawn worker: an unmerged one leaves through the kill question (D-06).
    /// `uat` is the G3 verdict (D-06): it counts only for a `cad-verify-p<N>` row, and checking or blocked turns all
    /// 3 merge routes off with the UAT reason in place of the pull request one.
    init(row: WorkerRow, pullRequest: PullRequestStore.State = .loaded(nil), uat: UATGate.Verdict = .notGated,
         override: UATOverride.Display = .hidden, ended: Bool = false) {
        overrideDisplay = override
        clearShown = ended
        clearLabel = row.agentId
        let finished = MergeModel.isFinished(row)
        markDoneShown = row.status == "running" && row.lastEvent != "done"
        let notFinished = "Merge is off: the worker is not finished (status \(row.status), last event \(row.lastEvent ?? "none"))"
        switch pullRequest {
        case .unselected, .loading:
            mergeHelp = "checking the pull request"
            summary = "checking the pull request"
        case .failed(let text):
            let reason = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            mergeHelp = "pull request lookup failed: \(reason), press Refresh"
            mergeAnywayEnabled = finished
            summary = "pull request lookup failed: \(reason)"
        case .loaded(nil):
            mergeEnabled = finished
            mergeHelp = finished ? "Show the merge preview" : notFinished
            summary = "no pull request"
        case .loaded(let pullRequest?):
            mergeEnabled = finished
            summary = "#\(pullRequest.number) \(pullRequest.title) (\(pullRequest.stateWords))"
            detail = "checks: \(pullRequest.checks.text), \(pullRequest.changedFiles) changed "
                + (pullRequest.changedFiles == 1 ? "file" : "files")
            if pullRequest.isOpen {
                mergeKind = .askOrchestrator(number: pullRequest.number)
                mergeTitle = "Ask orchestrator to merge PR #\(pullRequest.number)"
                mergeHelp = finished ? "Ask the orchestrator to merge this pull request" : notFinished
            } else {
                mergeHelp = finished ? "Show the merge preview" : notFinished
            }
        }
        guard UATGate.phase(ofLabel: row.agentId) != nil else { return }
        switch uat {
        case .checking: mergeHelp = "Merge is off: checking UAT"
        case .blocked(let reason): mergeHelp = "Merge is off: \(reason)"
        case .notGated, .confirmSkipped, .allowed: return
        }
        mergeEnabled = false
        mergeAnywayEnabled = false
    }
}

extension WorkerActions {
    /// The line under the strip after a Mark done run, or nil when it worked. The output is untrusted text (D-10):
    /// first line only, control characters removed, length capped.
    static func markDoneFailure(_ run: MergeReview.Run) -> String? {
        if run.failure == nil, run.status == 0 { return nil }
        let first = (run.failure?.text ?? run.output).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = String(String.UnicodeScalarView(first.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return "Mark done failed (exit \(run.status)): \(clean.prefix(200))"
    }
}

/// A slim strip under the panel header (D-04, D-05, D-06). It calls closures: `ContentView` owns the models and the sheets,
/// because this strip leaves the screen when the worker is deselected and would dismiss a sheet in the middle of a run.
/// Everything from `gh` is drawn as plain text.
struct WorkerActionsView: View {
    let actions: WorkerActions
    let onMerge: () -> Void
    let onTeardown: () -> Void
    var onMarkDone: () -> Void = {}
    var onClear: () -> Void = {}
    /// The pull request the strip describes, for the Files list and the Open PR button.
    var pullRequest: PullRequest?
    /// The result of the last "ask the orchestrator" press: "sent" or the refusal text.
    var requestText: String?
    var onMergeAnyway: () -> Void = {}
    var onRefresh: () -> Void = {}
    /// The G3 override flow of this worker. The reason lives in view state only and clears once a send starts.
    var overrideState = UATOverrideStore.State.idle
    var onOverride: (String) -> Void = { _ in }
    var onOverrideCancel: () -> Void = {}
    @State private var filesOpen = false
    @State private var overriding = false
    @State private var overrideReason = ""

    private var overrideLine: String? {
        switch overrideState {
        case .sending: return "Sending the capture request"
        case .waiting: return "Sent. Waiting for the worker to commit the capture and mark done again (approve its commit on the hold card)"
        case .refused(let why): return why
        case .idle, .granted: return nil
        }
    }

    @ViewBuilder private var overrideControls: some View {
        let busy = overrideState == .sending || overrideState == .waiting
        switch actions.overrideDisplay {
        case .hidden:
            EmptyView()
        case .off(let why):
            Button {} label: { KitLabel("Override", icon: .warning) }
                .buttonStyle(.kit).disabled(true).help(why).accessibilityLabel("Override")
        case .on where busy:
            if overrideState == .waiting {
                Button(action: onOverrideCancel) { Text("Cancel") }.buttonStyle(.kit)
            }
        case .on where overriding:
            TextField("Reason for the override", text: $overrideReason).textFieldStyle(.roundedBorder).frame(minWidth: Metric.nodeMinWidth * 2)
            Button { onOverride(overrideReason) } label: { Text("Send") }
                .buttonStyle(.kit).disabled(!UATResult.canSend(overrideReason))
            Button { overriding = false; overrideReason = ""; onOverrideCancel() } label: { Text("Cancel") }.buttonStyle(.kit)
        case .on:
            Button { overriding = true } label: { KitLabel("Override", icon: .warning) }
                .buttonStyle(.kit).help("Merge anyway: ask the worker to capture a reason").accessibilityLabel("Override")
        }
    }

    /// One bar: the buttons, then the pull request text (D-18). The text gives way first, then the labels go icon-only.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            row.labelStyle(.iconOnly)
        }
        .onChange(of: overrideState) { if overrideState == .waiting { overrideReason = ""; overriding = false } }
        .padding(.horizontal, Space.md).frame(height: Metric.dispatchBar)
        .background(Ink.header)
        .overlay(alignment: .bottom) { Ink.border.frame(height: Metric.hairline) }
    }

    private var row: some View {
        HStack(spacing: Space.sm) {
            Button(action: onMerge) { KitLabel(actions.mergeTitle, icon: .merge) }
                .buttonStyle(.kit).disabled(!actions.mergeEnabled)
                .help(actions.mergeHelp).accessibilityLabel(actions.mergeTitle)
            if actions.mergeAnywayEnabled {
                Button(action: onMergeAnyway) { KitLabel("Merge Locally Anyway", icon: .warning) }
                    .buttonStyle(.kit)
                    .help("The pull request state is unknown. Open the merge preview with a warning.")
                    .accessibilityLabel("Merge locally anyway")
            }
            overrideControls
            Button(action: onTeardown) { KitLabel("Teardown", icon: .delete) }
                .buttonStyle(.kit).disabled(!actions.teardownEnabled)
                .help("Close the worker and remove its worktree").accessibilityLabel("Teardown")
            if actions.clearShown {
                Button(action: onClear) { Text("Clear \(actions.clearLabel)") }
                    .buttonStyle(.kit)
                    .help("Stops the worker and frees the label. The branch stays as an orphaned session branch.")
            }
            if actions.markDoneShown {
                Button(action: onMarkDone) { KitLabel("Mark Done", icon: .done) }
                    .buttonStyle(.kit)
                    .help("Record that the worker is done, so Merge turns on").accessibilityLabel("Mark done")
            }
            // Its ideal width is 0, so the buttons count first and this takes only what they leave.
            HStack(spacing: Space.sm) {
                if let overrideLine {
                    Text(verbatim: overrideLine).kitType(.meta).foregroundStyle(Ink.muted).lineLimit(1).textSelection(.enabled)
                }
                if let requestText {
                    Text(verbatim: requestText).kitType(.meta).foregroundStyle(Ink.muted).lineLimit(1)
                        .textSelection(.enabled)
                }
                Text(verbatim: actions.summary).lineLimit(1).textSelection(.enabled)
                if let detail = actions.detail {
                    Text(verbatim: detail).lineLimit(1).foregroundStyle(Ink.muted)
                }
            }
            .kitType(.meta).foregroundStyle(Ink.textSecondary)
            .frame(minWidth: Space.none, idealWidth: Space.none, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .help([actions.summary, actions.detail].compactMap { $0 }.joined(separator: "\n"))
            if let pullRequest, !pullRequest.files.isEmpty {
                Button { filesOpen.toggle() } label: { Text("Files") }
                    .buttonStyle(.kit).accessibilityLabel("Files")
                    .popover(isPresented: $filesOpen) { filesList(pullRequest) }
            }
            Button(action: onRefresh) { KitLabel("Refresh", icon: .refresh) }
                .buttonStyle(.kit).help("Look up the pull request again").accessibilityLabel("Refresh")
            Button {
                if let url = pullRequest.flatMap({ PullRequest.openableURL($0.url) }) { NSWorkspace.shared.open(url) }
            } label: { KitLabel("Open PR", icon: .openExternal) }
                .buttonStyle(.kit)
                .disabled(pullRequest.flatMap { PullRequest.openableURL($0.url) } == nil)
                .help("Open the pull request on GitHub").accessibilityLabel("Open PR")
        }
    }

    private func filesList(_ pullRequest: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if pullRequest.filesCapped {
                Text(verbatim: "showing \(pullRequest.files.count) of \(pullRequest.changedFiles)")
                    .kitType(.meta).foregroundStyle(Ink.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(pullRequest.files.enumerated()), id: \.offset) { _, file in
                        Text(verbatim: "\(file.path)  +\(file.additions) -\(file.deletions)")
                            .kitType(.meta).foregroundStyle(Ink.textSecondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(Space.md).frame(width: Metric.filesPopoverWidth, height: Metric.filesPopoverHeight).background(Ink.panel)
    }
}
