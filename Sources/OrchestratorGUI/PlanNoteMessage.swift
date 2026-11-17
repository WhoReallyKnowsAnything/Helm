import Foundation

/// The one message a Notes press sends to the waiting plan worker (D-02). Pure: the only place the instruction text lives.
enum PlanNoteMessage {
    enum Refusal: Error, Equatable {
        case badPhase
        case emptyNotes
    }

    static let marker = "--- Notes from the user, follow them as written ---"

    /// The user's text is appended byte for byte: no trimming, no escaping, no length cap.
    static func make(phase: String, notes: String) -> Result<String, Refusal> {
        guard phase.range(of: #"\A[0-9]+(\.[0-9]+)?\z"#, options: .regularExpression) != nil else {
            return .failure(.badPhase)
        }
        guard !notes.allSatisfy(\.isWhitespace) else { return .failure(.emptyNotes) }
        return .success(instruction(phase) + "\n" + marker + "\n" + notes)
    }

    private static func instruction(_ n: String) -> String {
        "The user asks for changes to the plan for phase \(n). "
            + "Apply the notes below to the PLAN files in .planning/phases/\(n)/. "
            + "Then run /cadence:cad-plan-review \(n). "
            + "Then commit on your branch. Do not merge. "
            + "Last, mark the plan done again so it can be approved, because the commit replaces the done mark. "
            + "From the worktree root run: PROJECT_ROOT=$(cd \"$(git rev-parse --git-common-dir)/..\" && pwd); "
            + "ORCH_ROOT=$(cat \"$PROJECT_ROOT/.claude/orchestrator-root\"); "
            + "\"$ORCH_ROOT/orchestration/lib/dispatch-task.sh\" --mark-done cad-plan-p\(n). "
            + "If .claude/orchestrator-root is missing or empty, do not guess a path: tell the orchestrator with SendMessage. "
            + "Then end your turn."
    }
}
