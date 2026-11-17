import Foundation

/// Where the app finds tmux and the orchestrator clone. The app builds no tmux attach command any more.
enum OrchestratorPaths {
    /// A Finder launch inherits no shell PATH, so the app owns this one.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The folder that holds `orchestration/`. Never read a project file for it:
    /// a worker can write `.claude/orchestrator-root`.
    static let orchestratorRepo = orchestratorRoot(
        bundleResourceURL: Bundle.main.resourceURL,
        applicationSupport: realApplicationSupport())

    /// Bundled app: the runtime copy in `<Application Support>/Helm`. `swift test` and `swift run`
    /// have no bundled `orchestration`, so use the repo checkout.
    /// Fallback: `#filePath` is `<repo>/Sources/OrchestratorGUI/OrchestratorPaths.swift`, so drop 3 components.
    static func orchestratorRoot(bundleResourceURL: URL?, applicationSupport: URL, sourceFile: String = #filePath) -> String {
        if let res = bundleResourceURL,
           FileManager.default.fileExists(atPath: res.appendingPathComponent("orchestration").path) {
            return applicationSupport.appendingPathComponent("Helm").path
        }
        return URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// The real user's `~/Library/Application Support` from the passwd entry, not `$HOME`.
    static func realApplicationSupport() -> URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support")
    }

    /// First executable `tmux` in `searchPath`, in order (matches `command -v tmux` in the child).
    static func tmuxPath() -> String? {
        searchPath.split(separator: ":")
            .map { "\($0)/tmux" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// First executable `node` in `searchPath`, in order. `path` is injectable for tests.
    static func nodePath(searchPath path: String = searchPath) -> String? {
        path.split(separator: ":")
            .map { "\($0)/node" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
