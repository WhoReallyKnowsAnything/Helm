import SwiftUI

/// Opens a real file path in the in-app editor, at an optional line.
typealias OpenInEditor = (URL, Int?) -> Void

private struct OpenInEditorKey: EnvironmentKey {
    static let defaultValue: OpenInEditor? = nil
}

extension EnvironmentValues {
    /// Set by the main window. Nil means code links keep the VS Code route.
    var openInEditor: OpenInEditor? {
        get { self[OpenInEditorKey.self] }
        set { self[OpenInEditorKey.self] = newValue }
    }
}

/// Free text with its existing file paths drawn as links. A click opens through `FileOpener` and shows the outcome
/// under the text. Knows no screen. `canLink` lets a caller hide some candidates (for example absolute paths).
struct FileLinkView: View {
    let text: String
    let project: URL
    let worktree: URL?
    var canLink: (String) -> Bool = { _ in true }
    var workspace: WorkspaceOpening = SystemWorkspace()

    @Environment(\.openInEditor) private var openInEditor
    @State private var outcome: FileOpenOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(Self.attributed(text, project: project, worktree: worktree, canLink: canLink))
            if let outcome { Text(Self.describe(outcome)).font(.caption).foregroundStyle(.secondary) }
        }
        .environment(\.openURL, OpenURLAction { url in
            outcome = Self.handle(url, project: project, worktree: worktree, workspace: workspace, editor: openInEditor)
            return .handled
        })
        // A link run in Text has no press action for VoiceOver or a keyboard. The same text is read out, followed by one
        // button per link.
        .accessibilityRepresentation {
            VStack(alignment: .leading) {
                Text(text)
                ForEach(links, id: \.candidate) { link in
                    Button(link.label) {
                        outcome = Self.route(
                            link.candidate, project: project, worktree: worktree, workspace: workspace, editor: openInEditor)
                    }
                }
                if let outcome { Text(Self.describe(outcome)) }
            }
        }
    }

    private var links: [AccessibleLink] {
        Self.accessibleLinks(text, project: project, worktree: worktree, canLink: canLink)
    }

    struct AccessibleLink: Equatable {
        let candidate: String
        let label: String
    }

    /// One entry per distinct linked candidate in `text`, in order. The label names the file.
    static func accessibleLinks(_ text: String, project: URL, worktree: URL?, canLink: (String) -> Bool) -> [AccessibleLink] {
        var seen = Set<String>()
        return FileLinkText.split(text).compactMap { piece in
            guard case .candidate(let s) = piece, seen.insert(s).inserted,
                  linkURL(s, project: project, worktree: worktree, canLink: canLink) != nil else { return nil }
            return AccessibleLink(candidate: s, label: "Open \(s)")
        }
    }

    private static let scheme = "fileopen"

    /// The link URL for a candidate, or nil when it stays plain text.
    static func linkURL(
        _ candidate: String, project: URL, worktree: URL?, canLink: (String) -> Bool = { _ in true }
    ) -> URL? {
        guard canLink(candidate),
              case .success = FilePathResolver.resolve(candidate, project: project, worktree: worktree) else { return nil }
        return encode(candidate)
    }

    static func encode(_ candidate: String) -> URL? {
        guard let encoded = candidate.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "\(scheme)://open/\(encoded)")
    }

    static func candidate(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "open" else { return nil }
        return String(url.path(percentEncoded: true).dropFirst()).removingPercentEncoding
    }

    /// The click handler: decodes the link and opens it through `FileOpener`. Nil for a foreign URL.
    static func handle(
        _ url: URL, project: URL, worktree: URL?, workspace: WorkspaceOpening, editor: OpenInEditor? = nil
    ) -> FileOpenOutcome? {
        guard let text = candidate(from: url) else { return nil }
        return route(text, project: project, worktree: worktree, workspace: workspace, editor: editor)
    }

    /// The one route for a click and for the accessibility button. A code file goes to the editor action when one is
    /// set (nil outcome, nothing shown under the link). Everything else goes through `FileOpener` as before.
    static func route(
        _ text: String, project: URL, worktree: URL?, workspace: WorkspaceOpening, editor: OpenInEditor?
    ) -> FileOpenOutcome? {
        if let editor,
           case .success(let file) = FilePathResolver.resolve(text, project: project, worktree: worktree),
           FileOpenPolicy.decide(file.facts) == .editor {
            editor(file.url, FilePathResolver.lineNumber(in: text))
            return nil
        }
        return FileOpener.open(text, project: project, worktree: worktree, workspace: workspace)
    }

    static func describe(_ outcome: FileOpenOutcome) -> String {
        switch outcome {
        case .opened(let root, let app): "Opened the \(root.rawValue) copy in \(app)"
        case .refused(let reason): "Not opened: \(reason)"
        }
    }

    static func attributed(_ text: String, project: URL, worktree: URL?, canLink: (String) -> Bool) -> AttributedString {
        var result = AttributedString()
        for piece in FileLinkText.split(text) {
            switch piece {
            case .plain(let s):
                result += AttributedString(s)
            case .candidate(let s):
                var run = AttributedString(s)
                run.link = linkURL(s, project: project, worktree: worktree, canLink: canLink)
                result += run
            }
        }
        return result
    }
}
