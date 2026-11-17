import Foundation

struct LaunchResult: Equatable {
    /// The last non-empty stdout line of the launcher.
    let base: String
    /// Exit 3: a session for this project already ran.
    let reused: Bool
    /// What the launcher printed, kept to explain a later failure.
    let output: String
    /// The `folder=` line of a new project (stdout only); nil for the other starts.
    var folder: String? = nil
    /// The stderr lines that start `warning:`, verbatim; filled for a new project only.
    var warnings: [String] = []
}

struct LaunchFailure: Error, LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// Exit 4 of `--gui-new`: the project folder exists. A separate type, so the model can offer Select project.
struct ProjectExists: Error, LocalizedError, Equatable {
    let name: String
    var errorDescription: String? { "\(name) already exists in ~/Documents/Projects." }
}

/// Runs the orchestrator's non-interactive launcher (D-01 to D-03). The captured environment travels in a
/// private file, so no value from it reaches argv or the launcher's own environment.
enum ProjectLauncher {
    static let launcherPath = OrchestratorPaths.orchestratorRepo + "/orchestration/launch-claude.sh"

    static func launch(
        folder: String, envText: String, resumeId: String? = nil, launcher: String = launcherPath, timeout: TimeInterval = 60
    ) throws -> LaunchResult {
        try run(flags: ["--gui-folder", folder] + resumeFlags(resumeId), workingFolder: folder, envText: envText,
                launcher: launcher, timeout: timeout, resuming: resumeId != nil)
    }

    /// A plain solo session in the home folder: no orchestration, the default model (`--gui-root`).
    static func launchRoot(
        envText: String, resumeId: String? = nil, launcher: String = launcherPath, timeout: TimeInterval = 60
    ) throws -> LaunchResult {
        try run(flags: ["--gui-root"] + resumeFlags(resumeId), workingFolder: NSHomeDirectory(), envText: envText,
                launcher: launcher, timeout: timeout, resuming: resumeId != nil)
    }

    private static func resumeFlags(_ id: String?) -> [String] { id.map { ["--resume", $0] } ?? [] }

    static let createTimeout: TimeInterval = 120

    /// Creates `~/Documents/Projects/<name>` and starts it (`--gui-new`). The folder does not exist before the call,
    /// so the working folder is the home folder. Exit 4 throws `ProjectExists`.
    static func newProject(
        name: String, github: GithubChoice, envText: String, launcher: String = launcherPath,
        timeout: TimeInterval = createTimeout
    ) throws -> LaunchResult {
        try run(
            flags: ["--gui-new", name, "--github", github.rawValue], workingFolder: NSHomeDirectory(), envText: envText,
            launcher: launcher, timeout: timeout, creating: name)
    }

    /// `creating` is the project name of a `--gui-new` call: it maps exit 4, and reads the folder and warnings.
    private static func run(
        flags: [String], workingFolder: String, envText: String, launcher: String, timeout: TimeInterval,
        creating: String? = nil, resuming: Bool = false
    ) throws -> LaunchResult {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "orchestrator-gui-env-\(UUID().uuidString)"
        let file = dir + "/env"
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw LaunchFailure(reason: "Could not create a private folder for the environment: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(atPath: dir) }
        guard fm.createFile(atPath: file, contents: Data(envText.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw LaunchFailure(reason: "Could not write the environment file.")
        }

        let result = ProcessRunner.run(
            launcher, flags + ["--env-file", file],
            environment: TmuxRunner.environment(), workingFolder: workingFolder, timeout: timeout)
        let output = [result.stdout, result.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if let startError = result.startError { throw LaunchFailure(reason: "The launcher did not start: \(startError)") }
        if result.timedOut { throw LaunchFailure(reason: "The launcher timed out after \(Int(timeout)) seconds.\(output.isEmpty ? "" : "\n" + output)") }
        if let creating, result.status == 4 { throw ProjectExists(name: creating) }
        // A launcher without --resume support only reuses the running session, so exit 3 means nothing restarted.
        if resuming, result.status == 3 { throw LaunchFailure(reason: "The launcher did not restart the session (exit 3).\n" + output) }
        guard result.status == 0 || result.status == 3 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchFailure(reason: !stderr.isEmpty ? stderr : !stdout.isEmpty ? stdout : "The launcher exited \(result.status).")
        }
        guard let base = result.stdout.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else {
            throw LaunchFailure(reason: "The launcher printed no session name.")
        }
        guard creating != nil else { return LaunchResult(base: base, reused: result.status == 3, output: output) }
        // stdout only: stderr is the script's diagnostics, and a `folder=` there must not count.
        let prefix = "folder="
        guard let folder = result.stdout.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { $0.hasPrefix(prefix) }).map({ String($0.dropFirst(prefix.count)) }), !folder.isEmpty
        else { throw LaunchFailure(reason: "The launcher did not report the project folder.") }
        let warnings = result.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("warning:") }
        return LaunchResult(base: base, reused: result.status == 3, output: output, folder: folder, warnings: warnings)
    }
}
