import Foundation
import Testing
@testable import OrchestratorGUI

struct EnvironmentCaptureTests {
    private let dropped = [
        "TMUX", "TMUX_PANE", "TERM", "TERM_PROGRAM", "TERM_SESSION_ID", "ITERM_SESSION_ID", "LC_TERMINAL",
        "LC_TERMINAL_VERSION", "PWD", "OLDPWD", "SHLVL", "_", "CLAUDECODE", "LEAN_CTX_AGENT", "CODEBUDDY",
        "CODEX_CLI_SESSION", "GEMINI_SESSION",
    ]
    private let kept = [
        "PATH", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "LEAN_CTX_ENABLED", "LEAN_CTX_SHELL_ACTIVATION", "GEMINI_API_BASE_URL",
        "CONDA_PREFIX", "MYTERM", "ANTHROPIC_API_KEY",
    ]

    private func records(_ text: String) -> [EnvRecord] { EnvironmentCapture.keep(EnvironmentCapture.parse(text)) }

    @Test func dropsTerminalAndAgentNamesAndKeepsTheRest() {
        let text = (dropped + kept).map { "\($0)=v" }.joined(separator: "\n") + "\n"
        let names = records(text).map(\.name)
        for name in dropped { #expect(!names.contains(name), "\(name) should be dropped") }
        for name in kept { #expect(names.contains(name), "\(name) should survive") }
    }

    @Test func aTwoLineValueComesBackByteForByte() {
        let result = records("A=1\nKEY=-----BEGIN\nline2-----END\nB=2\n")
        #expect(result.first { $0.name == "KEY" }?.value == "-----BEGIN\nline2-----END")
        #expect(EnvironmentCapture.fileText(result) == "A=1\nKEY=-----BEGIN\nline2-----END\nB=2\n")
    }

    @Test func aBannerBeforeTheFirstRecordIsDropped() {
        #expect(records("Welcome back\n  ready\nPATH=/bin\n") == [EnvRecord(name: "PATH", value: "/bin")])
    }

    @Test func aRepeatedNameKeepsTheLastValue() {
        #expect(records("PATH=/a\nX=1\nPATH=/b\n") == [EnvRecord(name: "X", value: "1"), EnvRecord(name: "PATH", value: "/b")])
    }

    // MARK: capture with stub shells

    private func stub(_ body: String) throws -> String {
        let dir = NSTemporaryDirectory() + "env-capture-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/shell"
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func failure(_ shell: String, timeout: TimeInterval = 5) -> String? {
        do { _ = try EnvironmentCapture.capture(shell: shell, timeout: timeout); return nil } catch { return error.localizedDescription }
    }

    @Test func captureReturnsTheFilteredRecords() throws {
        let shell = try stub("printf 'banner\\nTMUX=x\\nPATH=/opt/bin:/bin\\nLEAN_CTX_ENABLED=1\\n'")
        let result = try EnvironmentCapture.capture(shell: shell, timeout: 5)
        #expect(EnvironmentCapture.fileText(result) == "PATH=/opt/bin:/bin\nLEAN_CTX_ENABLED=1\n")
    }

    @Test func captureFailureCarriesStderr() throws {
        let message = try #require(failure(try stub("echo 'zshrc wants a tty' >&2; exit 1")))
        #expect(message.contains("zshrc wants a tty"))
    }

    @Test func captureFailureSaysTimeout() throws {
        let message = try #require(failure(try stub("sleep 30"), timeout: 1))
        #expect(message.contains("timeout"))
    }

    @Test func captureFailureSaysThereIsNoPath() throws {
        let message = try #require(failure(try stub("echo LEAN_CTX_ENABLED=1")))
        #expect(message.contains("no PATH"))
    }
}
