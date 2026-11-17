import AppKit
import UniformTypeIdentifiers

/// The only door to `NSWorkspace`: app lookups and open calls. Tests swap in a recorder.
protocol WorkspaceOpening {
    func applicationURL(bundleIdentifier: String) -> URL?
    func plainTextEditorURL() -> URL?
    func open(_ file: URL)
    func open(_ file: URL, withApplicationAt app: URL)
}

struct SystemWorkspace: WorkspaceOpening {
    func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
    func plainTextEditorURL() -> URL? { NSWorkspace.shared.urlForApplication(toOpen: .plainText) }
    func open(_ file: URL) { NSWorkspace.shared.open(file) }
    func open(_ file: URL, withApplicationAt app: URL) {
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

enum FileOpenOutcome: Equatable {
    case opened(root: FileRoot, app: String)
    case refused(String)
}

/// D-09 and D-10 together: resolve, decide, open through `NSWorkspace` with an app location. No shell, no `Process`.
enum FileOpener {
    static let vsCodeBundleID = "com.microsoft.VSCode"
    static let defaultAppLabel = "default app"

    static func open(
        _ text: String, project: URL, worktree: URL?, workspace: WorkspaceOpening = SystemWorkspace()
    ) -> FileOpenOutcome {
        switch FilePathResolver.resolve(text, project: project, worktree: worktree) {
        case .failure(let refusal):
            return .refused(refusal.reason)
        case .success(let file):
            switch FileOpenPolicy.decide(file.facts) {
            case .refused(let reason):
                return .refused(reason)
            case .defaultApp:
                workspace.open(file.url)
                return .opened(root: file.root, app: defaultAppLabel)
            case .editor:
                guard let app = workspace.applicationURL(bundleIdentifier: vsCodeBundleID) ?? workspace.plainTextEditorURL() else {
                    return .refused("no editor found")
                }
                workspace.open(file.url, withApplicationAt: app)
                return .opened(root: file.root, app: app.deletingPathExtension().lastPathComponent)
            }
        }
    }
}
