import Foundation

/// The words the execute screen draws, built from the store's data, the overlay and the live flag. The view only draws this.
struct ExecuteScreenText: Equatable {
    struct Row: Equatable {
        let task: String
        let commit: String
        let note: String
    }

    struct PlanBlock: Equatable {
        /// "k. name [state]", plus "  FAILED" when the failure rule fires.
        let title: String
        let failure: Bool
        let rows: [Row]
        /// A checkpoint's type line, or a failure's first line, as written. Nil otherwise.
        let headline: String?
        /// The report body as written, for a checkpoint or a failure.
        let body: String?
        /// "git not checked: <reason>" when the hash check could not run. Nil otherwise.
        let gitLine: String?
        /// For a checkpoint with a live worker: "waiting for your answer" or the no-answer line. Nil otherwise.
        let answerLine: String?
    }

    struct Wave: Equatable {
        let title: String
        let plans: [PlanBlock]
    }

    let header: String
    /// Which copy is shown, nil when there is none.
    let copyLine: String?
    /// "not planned", an unreadable reason or nothing found.
    let message: String?
    let waves: [Wave]

    /// `questionOpen`: the worker has an AskUserQuestion card open. It beats the no-answer line (the coordinator asks at suite-red too).
    static func make(phase: String, data: ExecuteScreenData, overlay: WorkflowOverlay?, live: Bool, questionOpen: Bool = false) -> ExecuteScreenText {
        let header = "Execute: phase \(phase) - \(overlay?.text ?? "no worker")"
        guard data.source != .none else {
            return ExecuteScreenText(header: header, copyLine: nil, message: unreadableOrNothing(data), waves: [])
        }
        let copy = data.source == .worktree ? "worktree copy (not merged yet)" : "project copy"
        switch data.result {
        case .notPlanned:
            return ExecuteScreenText(header: header, copyLine: "Showing the \(copy)", message: "not planned", waves: [])
        case .unreadable(let reason):
            return ExecuteScreenText(header: header, copyLine: "Showing the \(copy)", message: reason, waves: [])
        case .loaded(let waves):
            let files = waves.map { $0.map(\.file) }
            let statuses = Dictionary(uniqueKeysWithValues: waves.flatMap { $0 }.compactMap { plan in
                plan.status.map { (plan.file, $0) }
            })
            let built = waves.enumerated().map { index, wave in
                Wave(title: "Wave \(index + 1)", plans: wave.map { block($0, files: files, statuses: statuses, live: live, questionOpen: questionOpen) })
            }
            return ExecuteScreenText(header: header, copyLine: "Showing the \(copy)",
                                     message: built.isEmpty ? "no plans found" : nil, waves: built)
        }
    }

    private static func unreadableOrNothing(_ data: ExecuteScreenData) -> String {
        if case .unreadable(let reason) = data.result { return reason }
        return "nothing found"
    }

    private static func block(_ plan: ExecuteScreenData.PlanData, files: [[String]], statuses: [String: String],
                              live: Bool, questionOpen: Bool) -> PlanBlock {
        let resolved = ExecutePlanState.resolve(file: plan.file, waves: files, statuses: statuses, live: live)
        let word: String
        switch resolved.state {
        case .waiting: word = "waiting"
        case .running: word = "running"
        case .done: word = "done"
        case .partial: word = "partial"
        case .checkpoint: word = "checkpoint"
        }
        let title = "\(plan.k). \(plan.name ?? plan.file) [\(word)]\(resolved.failure ? "  FAILED" : "")"
        let reportRows = plan.report?.rows ?? []
        // The executor writes the report late; until it lists as many rows as git has commits, git's rows show.
        let rows = reportRows.count >= plan.gitRows.count ? reportRows.enumerated().map { index, row in
            var missing = false
            if case .checked(let list)? = plan.commits, list.indices.contains(index), list[index] == .missing { missing = true }
            return Row(task: row.task, commit: row.commit, note: missing ? "\(row.note) not found in git".trimmingCharacters(in: .whitespaces) : row.note)
        } : plan.gitRows.map { Row(task: $0.task, commit: $0.commit, note: $0.note) }
        var gitLine: String?
        if case .unchecked(let reason)? = plan.commits { gitLine = "git not checked: \(reason)" }
        // User-directed (plan 2): the body is not dumped; only the report's first line and its Need: line show.
        let need = plan.report?.body.components(separatedBy: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Need:") }?.trimmingCharacters(in: .whitespaces)
        var headline: String?
        var body: String?
        if case .checkpoint = resolved.state {
            headline = plan.report?.firstLine ?? plan.status
            body = need
        }
        if resolved.failure {
            headline = plan.report?.firstLine ?? plan.status
            body = need
        }
        var answerLine: String?
        if live, case .checkpoint(let type) = resolved.state {
            answerLine = questionOpen || ExecutePlanState.takesAnswer(type) ? "waiting for your answer" : "no answer needed: the next executor starts by itself"
        }
        return PlanBlock(title: title, failure: resolved.failure, rows: rows, headline: headline, body: body, gitLine: gitLine,
                         answerLine: answerLine)
    }
}
