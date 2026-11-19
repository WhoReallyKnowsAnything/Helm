import Foundation

/// How to start the user's own shell: a login zsh in a folder (D-09).
/// `environment` is an array of `KEY=VALUE` strings, the form SwiftTerm's `startProcess` takes.
struct ShellLaunch: Equatable {
    let executable = "/bin/zsh"
    let arguments = ["-l"]
    let environment: [String]
    let folder: String

    /// Keeps the parent's variables, sets `TERM`, and drops `CLAUDE_GUI` whatever its value.
    init(folder: String, parentEnvironment: [String: String]) {
        var env = parentEnvironment
        env["CLAUDE_GUI"] = nil
        env["TERM"] = "xterm-256color"
        self.environment = env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
        self.folder = folder
    }

    /// The root screen: the home folder, read at call time.
    static func home(parentEnvironment: [String: String]) -> ShellLaunch {
        ShellLaunch(folder: NSHomeDirectory(), parentEnvironment: parentEnvironment)
    }
}
