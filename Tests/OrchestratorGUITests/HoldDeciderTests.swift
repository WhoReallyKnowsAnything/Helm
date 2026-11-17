import Foundation
import Testing
@testable import OrchestratorGUI

@Suite(.serialized) struct HoldDeciderTests {
    private let hash = String(repeating: "a", count: 64)
    private static let gateLibrary = OrchestratorPaths.orchestratorRepo + "/orchestration/lib/gate-hold.sh"

    /// The gate's own signal (`--gate-decide` in dispatch-task.sh): it refuses a caller with an ancestor launched with
    /// the worker prompt, and any caller with no decider ancestor (the drafting-prompt claude or the app), such as a
    /// detached shell. The real-script test cannot pass there.
    private static let gateRefuses: Bool = {
        var pid = getppid()
        var decider = false
        while pid > 1 {
            let ps = ProcessRunner.run("/bin/ps", ["-o", "ppid=,args=", "-p", String(pid)], environment: [:], timeout: 5)
            let line = ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { break }
            let withPrompt = line.contains(" --append-system-prompt-file ")
            if withPrompt && line.contains("/orchestration/prompts/worker-dependency-awareness.md") { return true }
            if (withPrompt && line.contains("/orchestration/prompts/task-drafting-mode.md"))
                || line.contains("/OrchestratorGUI.app/Contents/MacOS/OrchestratorGUI")
                || line.contains("/Canopy-Foreman.app/Contents/MacOS/OrchestratorGUI")
                || line.contains("/Helm.app/Contents/MacOS/OrchestratorGUI") { decider = true }
            guard let next = line.split(separator: " ").first.flatMap({ Int32($0) }) else { break }
            pid = next
        }
        return !decider
    }()

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

    /// A stub for `dispatch-task.sh`: `body` is its shell text. `$MARK` is a file the stub writes to.
    private func stub(_ body: String) throws -> (path: String, mark: String) {
        let dir = NSTemporaryDirectory() + "decide-stub-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/stub.sh", mark = dir + "/mark"
        try "#!/bin/bash\nMARK='\(mark)'\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, mark)
    }

    /// Sets both markers a Claude Code shell carries for the length of `body`, then restores them.
    private func withClaudeMarkers<T>(_ body: () throws -> T) rethrows -> T {
        let names = ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID"]
        let old = names.map { getenv($0).map { String(cString: $0) } }
        for name in names { setenv(name, "1", 1) }
        defer { for (name, value) in zip(names, old) { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }
        return try body()
    }

    private func decide(_ choice: HoldChoice, folder: String, script: String, timeout: TimeInterval = 10) -> HoldDecision {
        HoldDecider.decide(
            label: "bravo", id: "toolu_A", choice: choice, hash: hash, folder: folder, script: script, timeout: timeout)
    }

    private func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    private let recordEverything = #"""
    printf '%s\n' "$@" > "$MARK"
    { echo "ROOT=$ORCH_PROJECT_ROOT"; echo "CC=${CLAUDECODE-unset}"; echo "SID=${CLAUDE_CODE_SESSION_ID-unset}"; echo "PWD=$(pwd -P)"; } >> "$MARK"
    """#

    @Test(arguments: [HoldChoice.allow, HoldChoice.deny])
    func passesExactlyTheDecideArgumentsAndACleanEnvironment(choice: HoldChoice) throws {
        let folder = try newFolder()
        let s = try stub(recordEverything)
        let result = withClaudeMarkers { decide(choice, folder: folder, script: s.path) }
        #expect(result == .delivered)
        let lines = try String(contentsOfFile: s.mark, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [
            "--gate-decide", "bravo", "toolu_A", choice.rawValue, hash,
            "ROOT=\(folder)", "CC=unset", "SID=unset",
            "PWD=\(realPath(folder))",
        ])
    }

    @Test func theEnvironmentIsTheTmuxOneAndTheProjectRoot() {
        var expected = TmuxRunner.environment()
        expected["ORCH_PROJECT_ROOT"] = "/some/project"
        #expect(HoldDecider.environment(folder: "/some/project") == expected)
    }

    @Test func exitZeroIsDelivered() throws {
        #expect(decide(.allow, folder: try newFolder(), script: try stub("exit 0").path) == .delivered)
    }

    @Test(arguments: [
        "Error: --gate-decide refused: the hold is no longer waiting",
        "Error: --gate-decide refused: no pending hold for that tool_use_id",
    ])
    func aHoldThatEndedIsNotAnError(line: String) throws {
        let s = try stub("echo '\(line)' >&2; exit 1")
        #expect(decide(.deny, folder: try newFolder(), script: s.path) == .alreadyDecided)
    }

    @Test func anyOtherRefusalShowsItsLastNonEmptyStderrLine() throws {
        let line = "Error: --gate-decide refused: the caller is a Claude Code session, only the band may decide a hold"
        let s = try stub("echo 'first' >&2; echo '\(line)' >&2; echo >&2; exit 1")
        #expect(decide(.allow, folder: try newFolder(), script: s.path) == .failed(line))
    }

    @Test func aFailureWithoutTextShowsTheExitCode() throws {
        #expect(decide(.allow, folder: try newFolder(), script: try stub("exit 3").path) == .failed("exit code 3"))
    }

    @Test func aScriptThatOutlastsTheTimeoutIsAnError() throws {
        let s = try stub("sleep 30")
        let result = decide(.allow, folder: try newFolder(), script: s.path, timeout: 0.5)
        guard case .failed(let text) = result else { Issue.record("expected a failure, got \(result)"); return }
        #expect(text.contains("took more than"))
    }

    @Test func aMissingScriptIsAnError() throws {
        let result = decide(.allow, folder: try newFolder(), script: "/nonexistent/dispatch-task.sh")
        guard case .failed(let text) = result else { Issue.record("expected a failure, got \(result)"); return }
        #expect(text.contains("not an executable file"))
    }

    /// Runs the landed script against a real hold from the landed gate library. The test process carries both
    /// Claude Code markers, so a pass proves the decider's environment does not.
    @Test(
        .enabled(if: FileManager.default.fileExists(atPath: HoldDeciderTests.gateLibrary)),
        .enabled(if: !HoldDeciderTests.gateRefuses, "the gate refuses a caller inside a dispatched worker; run this from the orchestrator session"))
    func decidesARealHoldFromTheLandedScript() throws {
        let folder = try newFolder()
        let out = NSTemporaryDirectory() + "hold-outcome-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(atPath: folder)
            try? FileManager.default.removeItem(atPath: out)
        }
        let git = ProcessRunner.run("/usr/bin/git", ["init", "-q", folder], environment: TmuxRunner.environment(), timeout: 10)
        try #require(git.status == 0)
        // gate_hold_run records a `blocked` event; without the sessions table it logs a DB error.
        let initDB = ProcessRunner.run(
            OrchestratorPaths.orchestratorRepo + "/orchestration/init/init-state-store.sh", [folder],
            environment: TmuxRunner.environment(), timeout: 10)
        try #require(initDB.status == 0)

        let hook = Process()
        hook.executableURL = URL(fileURLWithPath: "/bin/bash")
        hook.arguments = ["-c", """
            source "$GATE_LIB"
            d=$(gate_hold_dir .) || exit 2
            H=$(gate_hold_op_hash Bash 'git push origin main')
            gate_hold_run "$d" toolu_real bravo "$H" "$PWD" Bash 'git push origin main' 20
            echo "$GATE_HOLD_OUTCOME" > "$OUT"
            """]
        hook.currentDirectoryURL = URL(fileURLWithPath: folder)
        hook.environment = TmuxRunner.environment().merging(["GATE_LIB": Self.gateLibrary, "OUT": out]) { _, new in new }
        try hook.run()
        defer { if hook.isRunning { hook.terminate() } }

        let pending = folder + "/.claude/gate-holds/toolu_real.pending"
        try #require(waitUntil { FileManager.default.fileExists(atPath: pending) })
        let header = try String(contentsOfFile: pending, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        let realHash = String(header[1])

        let result = withClaudeMarkers {
            HoldDecider.decide(label: "bravo", id: "toolu_real", choice: .allow, hash: realHash, folder: folder)
        }
        #expect(result == .delivered)
        try #require(waitUntil { FileManager.default.fileExists(atPath: out) })
        #expect(try String(contentsOfFile: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "allow")
    }
}
