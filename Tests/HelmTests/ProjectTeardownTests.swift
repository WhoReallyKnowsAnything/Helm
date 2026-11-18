import Foundation
import Testing
@testable import Helm

@Suite(.serialized) struct ProjectTeardownTests {
    private func hex8() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    /// A `gui-test-<8 hex>` folder, so the derived session name equals its basename.
    private func newFolder() throws -> (folder: String, base: String) {
        let base = "gui-test-" + hex8()
        let dir = NSTemporaryDirectory() + base
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir, base)
    }

    /// A stub teardown script: `body` is its shell text. `$MARK` is a file the stub appends its arguments to.
    private func stub(_ body: String) throws -> (path: String, mark: String) {
        let dir = NSTemporaryDirectory() + "teardown-stub-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/stub.sh", mark = dir + "/mark"
        try "#!/bin/bash\nMARK='\(mark)'\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, mark)
    }

    private func failure(_ block: () throws -> Void) -> String? {
        do { try block() } catch { return error.localizedDescription }
        return nil
    }

    @Test func passesExactlyTheTeardownFlagAndTheFolder() throws {
        let (folder, base) = try newFolder()
        let s = try stub(#"printf '%s\n' "$@" > "$MARK""#)
        try ProjectTeardown.stop(folder: folder, sessionId: base, script: s.path)
        let args = try String(contentsOfFile: s.mark, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args == ["--teardown-project", folder])
    }

    @Test func exitOneIsAFailureCarryingStderr() throws {
        let (folder, base) = try newFolder()
        let s = try stub(#"echo "Error: refused because reasons" >&2; exit 1"#)
        let reason = failure { try ProjectTeardown.stop(folder: folder, sessionId: base, script: s.path) }
        #expect(reason?.contains("refused because reasons") == true)
    }

    @Test func aMissingScriptIsAFailure() throws {
        let (folder, base) = try newFolder()
        let reason = failure { try ProjectTeardown.stop(folder: folder, sessionId: base, script: "/nonexistent/dispatch-task.sh") }
        #expect(reason?.contains("not an executable file") == true)
    }

    @Test func aSessionIdThatDoesNotMatchTheFolderRunsNothing() throws {
        let (folder, _) = try newFolder()
        let s = try stub(#"echo ran > "$MARK""#)
        let reason = failure { try ProjectTeardown.stop(folder: folder, sessionId: "another-project", script: s.path) }
        #expect(reason?.contains("another-project") == true)
        #expect(!FileManager.default.fileExists(atPath: s.mark))
    }

    @Test func anEmptyFolderRunsNothing() throws {
        let s = try stub(#"echo ran > "$MARK""#)
        let reason = failure { try ProjectTeardown.stop(folder: "", sessionId: "x", script: s.path) }
        #expect(reason != nil)
        #expect(!FileManager.default.fileExists(atPath: s.mark))
    }

    // MARK: real tmux (a private server per test, never the default one)

    private static let realScriptExists = FileManager.default.isExecutableFile(atPath: ProjectTeardown.defaultScript)
        && OrchestratorPaths.tmuxPath() != nil

    private func tmux(_ socket: String, _ args: [String]) -> ProcessResult {
        ProcessRunner.run(
            OrchestratorPaths.tmuxPath() ?? "/usr/bin/false", ["-L", socket] + args,
            environment: TmuxRunner.environment(socket: socket), timeout: 5)
    }

    private func sessionNames(_ socket: String) -> Set<String> {
        Set(tmux(socket, ["list-sessions", "-F", "#{session_name}"]).stdout.split(separator: "\n").map(String.init))
    }

    @Test(.enabled(if: realScriptExists)) func stopsTheBaseAndItsClientButNotASiblingOrAnyOtherSession() throws {
        let (folder, base) = try newFolder()
        let client = base + "-dashboard", sibling = base + "-sibling"
        let socket = "gui-test-" + hex8()
        defer { _ = tmux(socket, ["kill-server"]) }
        #expect(tmux(socket, ["new-session", "-d", "-s", base, "-n", "dashboard", "-c", folder, "sleep 60"]).status == 0)
        #expect(tmux(socket, ["new-session", "-d", "-s", client, "-t", base]).status == 0)
        #expect(tmux(socket, ["new-session", "-d", "-s", sibling, "sleep 60"]).status == 0)

        try ProjectTeardown.stop(folder: folder, sessionId: base, socket: socket)

        let after = sessionNames(socket)
        #expect(!after.contains(base) && !after.contains(client))
        #expect(after == [sibling])
    }

    @Test(.enabled(if: realScriptExists)) func aSessionThatStaysRunningIsAFailure() throws {
        let (folder, base) = try newFolder()
        let socket = "gui-test-" + hex8()
        defer { _ = tmux(socket, ["kill-server"]) }
        #expect(tmux(socket, ["new-session", "-d", "-s", base, "-n", "dashboard", "-c", folder, "sleep 60"]).status == 0)
        let s = try stub("exit 0")
        let reason = failure { try ProjectTeardown.stop(folder: folder, sessionId: base, script: s.path, socket: socket) }
        #expect(reason?.contains("still running") == true)
    }
}
