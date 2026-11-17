import Foundation
import Testing
@testable import OrchestratorGUI

@Suite(.serialized) struct MergeReviewTests {
    // The marker, cancel and refusal lines are the script's own echo lines (merge-review.sh:193,247,354,398);
    // the integration suite runs the real script.
    private let mergedOutput = """
    Merging session/alpha into main
    no such table: sessions
    ✓ Merge complete: session/alpha → main
    """
    private let refusal = "Error: session/beta is not merged into main (no ancestry, no matching tree, no merged PR for its current tip); nothing torn down"

    // MARK: classification

    @Test func theMarkerWithExitZeroIsMerged() {
        #expect(MergeReview.classifyMerge(label: "alpha", status: 0, output: mergedOutput) == .merged)
    }

    @Test func aCancelledRunIsNeverMergedEvenWithExitZero() {
        let output = mergedOutput + "\nMerge cancelled."
        #expect(MergeReview.classifyMerge(label: "alpha", status: 0, output: output) == .cancelled)
        #expect(MergeReview.classifyMerge(label: "alpha", status: 0, output: "Merge cancelled.\n") == .cancelled)
    }

    @Test func theMarkerOfOneLabelDoesNotMergeAnotherWithAPrefix() {
        #expect(MergeReview.classifyMerge(label: "alp", status: 0, output: mergedOutput) == .failed(status: 0))
    }

    @Test func theMarkerWithExitOneIsNotMerged() {
        #expect(MergeReview.classifyMerge(label: "alpha", status: 1, output: mergedOutput) == .failed(status: 1))
    }

    @Test func exitZeroWithoutAMarkerIsFailed() {
        #expect(MergeReview.classifyMerge(label: "alpha", status: 0, output: "nothing\n") == .failed(status: 0))
    }

    @Test func aMarkerQuotedInsideAnotherLineDoesNotCount() {
        let output = "note: ✓ Merge complete: session/alpha → main\n"
        #expect(MergeReview.classifyMerge(label: "alpha", status: 0, output: output) == .failed(status: 0))
    }

    @Test func teardownExitZeroIsDone() {
        #expect(MergeReview.classifyTeardown(status: 0, output: "removed\n") == .done)
    }

    @Test func theRefusalTextWithExitOneIsNotMerged() {
        #expect(MergeReview.classifyTeardown(status: 1, output: refusal) == .notMerged)
    }

    @Test func anyOtherTeardownFailureIsFailed() {
        #expect(MergeReview.classifyTeardown(status: 1, output: "Error: another merge-review is in progress") == .failed(status: 1))
    }

    // MARK: runs

    private func newFolder() throws -> String {
        let dir = NSTemporaryDirectory() + "gui-test-" + String(UUID().uuidString.prefix(8)).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// What `pwd -P` prints: `URL.resolvingSymlinksInPath` drops the `/private` prefix of `/var`.
    private func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A stub for the script: `body` is its shell text. `$MARK` is a file the stub writes to.
    private func stub(_ body: String) throws -> (path: String, mark: String) {
        let dir = NSTemporaryDirectory() + "merge-stub-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/stub.sh", mark = dir + "/mark"
        try "#!/bin/bash\nMARK='\(mark)'\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, mark)
    }

    /// Records argv, the working folder, one environment variable and stdin (as bytes in `$MARK.stdin`).
    private let recordEverything = #"""
    printf '%s\n' "$@" > "$MARK"
    { echo "PWD=$(pwd -P)"; echo "KEEP=${KEEP-unset}"; echo "CC=${CLAUDECODE-unset}"; } >> "$MARK"
    cat > "$MARK.stdin"
    """#

    private let environment = ["PATH": OrchestratorPaths.searchPath, "KEEP": "yes"]

    private func lines(_ path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// Sets `CLAUDECODE` for the length of `body`, then restores it.
    private func withClaudeMarker<T>(_ body: () throws -> T) rethrows -> T {
        let old = getenv("CLAUDECODE").map { String(cString: $0) }
        setenv("CLAUDECODE", "1", 1)
        defer { if let old { setenv("CLAUDECODE", old, 1) } else { unsetenv("CLAUDECODE") } }
        return try body()
    }

    @Test func previewPassesTheLabelAloneWithClosedStdin() throws {
        let folder = try newFolder(), s = try stub(recordEverything)
        let run = withClaudeMarker { MergeReview.preview(label: "alpha", folder: folder, environment: environment, script: s.path) }
        #expect(run.failure == nil)
        #expect(try lines(s.mark) == ["alpha", "PWD=\(realPath(folder))", "KEEP=yes", "CC=unset"])
        #expect(try String(contentsOfFile: s.mark + ".stdin", encoding: .utf8) == "")
    }

    @Test func mergePassesTheFlagAndExactlyYAndANewlineOnStdin() throws {
        let folder = try newFolder(), s = try stub(recordEverything)
        let run = MergeReview.merge(label: "alpha", folder: folder, environment: environment, script: s.path)
        #expect(run.failure == nil)
        #expect(try lines(s.mark).prefix(2) == ["alpha", "--merge"])
        #expect(try String(contentsOfFile: s.mark + ".stdin", encoding: .utf8) == "y\n")
        #expect(!(try lines(s.mark)).contains("--yes"))
    }

    @Test func teardownPassesTheFlag() throws {
        let folder = try newFolder(), s = try stub(recordEverything)
        _ = MergeReview.teardown(label: "alpha", folder: folder, environment: environment, script: s.path)
        #expect(try lines(s.mark).prefix(2) == ["alpha", "--teardown"])
        #expect(!(try lines(s.mark)).contains("--yes"))
    }

    @Test func killPassesTheFlagFirst() throws {
        let folder = try newFolder(), s = try stub(recordEverything)
        _ = MergeReview.kill(label: "alpha", folder: folder, environment: environment, script: s.path)
        #expect(try lines(s.mark).prefix(2) == ["--kill", "alpha"])
    }

    @Test func markDonePassesTheFlagAndLabelAndRunsInTheWorktree() throws {
        let worktree = try newFolder(), s = try stub(recordEverything)
        let run = MergeReview.markDone(label: "alpha", worktree: worktree, environment: environment, script: s.path)
        #expect(run.failure == nil)
        #expect(try lines(s.mark) == ["--mark-done", "alpha", "PWD=\(realPath(worktree))", "KEEP=yes", "CC=unset"])
    }

    @Test func markDoneUsesTheOrchestratorDispatchScriptByDefault() {
        #expect(HoldDecider.defaultScript == OrchestratorPaths.orchestratorRepo + "/orchestration/lib/dispatch-task.sh")
    }

    @Test(arguments: ["-x", "a b", "a/b", ""])
    func markDoneWithAnInvalidLabelStartsNothing(label: String) throws {
        let worktree = try newFolder(), s = try stub(recordEverything)
        let run = MergeReview.markDone(label: label, worktree: worktree, environment: environment, script: s.path)
        #expect(run.failure == .invalidLabel(label))
        #expect(!FileManager.default.fileExists(atPath: s.mark))
    }

    @Test(arguments: [nil, ""] as [String?])
    func markDoneWithoutAWorktreePathStartsNothing(worktree: String?) throws {
        let s = try stub(recordEverything)
        let run = MergeReview.markDone(label: "alpha", worktree: worktree, environment: environment, script: s.path)
        #expect(run.failure != nil)
        #expect(run.status == -1)
        #expect(!FileManager.default.fileExists(atPath: s.mark))
    }

    @Test func theStatusAndTheOutputOfBothStreamsComeBackInOrder() throws {
        let s = try stub("echo one; echo two >&2; echo three; exit 1")
        let run = MergeReview.preview(label: "alpha", folder: try newFolder(), environment: environment, script: s.path)
        #expect(run.output == "one\ntwo\nthree\n")
        #expect(run.status == 1)
        #expect(run.failure == nil)
    }

    @Test(arguments: ["-x", "a b", "a/b", ""])
    func anInvalidLabelStartsNothing(label: String) throws {
        let folder = try newFolder(), s = try stub(recordEverything)
        let runs = [
            MergeReview.preview(label: label, folder: folder, environment: environment, script: s.path),
            MergeReview.merge(label: label, folder: folder, environment: environment, script: s.path),
            MergeReview.teardown(label: label, folder: folder, environment: environment, script: s.path),
            MergeReview.kill(label: label, folder: folder, environment: environment, script: s.path),
        ]
        #expect(runs.allSatisfy { $0.failure == .invalidLabel(label) })
        #expect(!FileManager.default.fileExists(atPath: s.mark))
    }

    @Test func aRunPastItsTimeoutIsStoppedAndSaysSo() throws {
        let s = try stub("echo started; sleep 5")
        let run = MergeReview.preview(label: "alpha", folder: try newFolder(), environment: environment, script: s.path, timeout: 0.3)
        #expect(run.failure == .timedOut(seconds: 1))
        #expect(run.failure?.text.contains("stopped") == true)
        #expect(run.failure?.text.contains("half done") == true)
        #expect(run.output.contains("started"))
    }

    @Test func aMissingScriptGivesAFailureText() throws {
        let run = MergeReview.merge(label: "alpha", folder: try newFolder(), environment: environment, script: "/nonexistent/merge-review.sh")
        guard case .didNotStart(let reason)? = run.failure else { Issue.record("expected didNotStart, got \(String(describing: run.failure))"); return }
        #expect(reason.contains("/nonexistent/merge-review.sh"))
    }

    @Test func theScriptPathsAreTheOrchestratorOnes() {
        #expect(MergeReview.script == OrchestratorPaths.orchestratorRepo + "/orchestration/merge-review.sh")
        #expect(HoldDecider.defaultScript.hasSuffix("/orchestration/lib/dispatch-task.sh"))
    }

    // MARK: labels

    @Test(arguments: ["alpha", "fix-login.2", "a", "7up", "a_b"])
    func aPlainLabelIsAccepted(label: String) {
        #expect(MergeReview.isValidLabel(label))
    }

    @Test(arguments: ["-x", "a b", "a/b", "", ".hidden", "_x", "a\nb", "ä"])
    func anUnsafeLabelIsRefused(label: String) {
        #expect(!MergeReview.isValidLabel(label))
    }
}
