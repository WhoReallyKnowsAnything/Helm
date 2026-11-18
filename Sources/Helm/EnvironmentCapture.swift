import Foundation

struct EnvRecord: Equatable {
    let name: String
    let value: String
}

struct EnvironmentCaptureFailure: Error, LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// The user's own shell environment (D-06, D-07), so a project started from the app sees the same PATH and
/// keys as one started from iTerm. The parse and filter step is pure; `capture` is the only process step.
enum EnvironmentCapture {
    private static let droppedPrefixes = ["TMUX", "TERM", "ITERM_", "LC_TERMINAL"]
    /// An agent marker left in would make the `~/.zshenv` lean-ctx hook wrap the pane command and break the session.
    private static let droppedNames: Set<String> = [
        "PWD", "OLDPWD", "SHLVL", "_", "CLAUDECODE", "LEAN_CTX_AGENT", "CODEBUDDY", "CODEX_CLI_SESSION", "GEMINI_SESSION",
    ]

    /// The launcher's env file reader: `NAME=` starts a record, any other line continues the previous one,
    /// lines before the first record are dropped, a repeated name keeps the last value.
    static func parse(_ text: String) -> [EnvRecord] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var records: [(name: String, value: String)] = []
        for line in lines {
            if let (name, value) = splitRecord(line) {
                if let at = records.firstIndex(where: { $0.name == name }) { records.remove(at: at) }
                records.append((name, value))
            } else if !records.isEmpty {
                records[records.count - 1].value += "\n" + line
            }
        }
        return records.map { EnvRecord(name: $0.name, value: $0.value) }
    }

    private static func splitRecord(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { return nil }
        let name = line[..<eq]
        let valid = name.unicodeScalars.enumerated().allSatisfy { index, scalar in
            let letter = (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) || scalar == "_"
            return letter || (index > 0 && scalar.value >= 48 && scalar.value <= 57)
        }
        return valid ? (String(name), String(line[line.index(after: eq)...])) : nil
    }

    static func keep(_ records: [EnvRecord]) -> [EnvRecord] {
        records.filter { record in
            !droppedNames.contains(record.name) && !droppedPrefixes.contains { record.name.hasPrefix($0) }
        }
    }

    /// `NAME=value` per record, in capture order, multi-line values intact.
    static func fileText(_ records: [EnvRecord]) -> String {
        records.map { "\($0.name)=\($0.value)\n" }.joined()
    }

    static func defaultShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    /// Login-only misses `.zshrc`, which holds the PATH and the exported keys, so the shell is also interactive.
    static func capture(shell: String = defaultShell(), timeout: TimeInterval = 10) throws -> [EnvRecord] {
        // The shell needs the app's own HOME and USER to find `.zshrc`.
        let result = ProcessRunner.run(
            shell, ["-l", "-i", "-c", "env"], environment: ProcessInfo.processInfo.environment, timeout: timeout)
        if let startError = result.startError { throw EnvironmentCaptureFailure(reason: "Shell did not start: \(startError)") }
        if result.timedOut {
            throw EnvironmentCaptureFailure(reason: "Environment capture timeout: \(shell) did not finish in \(Int(timeout)) seconds. A .zshrc that waits for input is the usual cause.")
        }
        guard result.status == 0 else {
            let detail = String(result.stderr.prefix(300))
            throw EnvironmentCaptureFailure(reason: "Environment capture failed: \(shell) exited \(result.status). \(detail)")
        }
        let kept = keep(parse(result.stdout))
        guard kept.contains(where: { $0.name == "PATH" }) else {
            throw EnvironmentCaptureFailure(reason: "Environment capture found no PATH. A launch without it cannot find claude, lean-ctx or node.")
        }
        return kept
    }
}
