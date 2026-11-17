import Foundation

/// The slash-command menu list (D-14), built from the newest `init` event and the prompt text.
enum SlashMenu {
    /// The only built-in commands the menu offers. Every other built-in is terminal-only.
    static let allowedBuiltIns: Set<String> = ["context", "model", "effort", "compact"]
    static let maxEntries = 50

    /// Names in menu order. Empty unless the text starts with `/` and holds no whitespace yet.
    static func entries(slashCommands: [String], skills: [String], text: String) -> [String] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let typed = text.dropFirst().lowercased()
        let skillSet = Set(skills)
        let kept = Set(slashCommands.filter { skillSet.contains($0) || $0.contains(":") || allowedBuiltIns.contains($0) })
            .union(Native.allCases.map(\.rawValue))
        // String.contains("") is false, so a bare "/" must skip the filter.
        let matches = kept.sorted().filter { typed.isEmpty || $0.lowercased().contains(typed) }
        let prefixed = matches.filter { $0.lowercased().hasPrefix(typed) }
        let rest = matches.filter { !$0.lowercased().hasPrefix(typed) }
        return Array((prefixed + rest).prefix(maxEntries))
    }

    /// The draft after a pick: `/name ` replaces whatever was typed.
    static func pick(_ name: String) -> String { "/\(name) " }

    /// Commands the app answers with its own sheet instead of sending (D-04).
    enum Native: String, CaseIterable, Identifiable {
        case permissions, mcp, resume, config, login, logout, status
        var id: String { rawValue }
    }

    enum Action: Equatable {
        case native(Native)
        case note(String)
        case send
    }

    /// Interactive-only built-ins with no headless form (D-06), on top of init's `terminal_slash_commands`.
    static let noteOnly: Set<String> = [
        "theme", "vim", "hooks", "terminal-setup", "ide", "install-github-app",
        "privacy-settings", "upgrade", "bug", "release-notes", "statusline", "output-style-new",
    ]

    /// What Send or a pick does with `text`: open a sheet, show a note, or send it as is (D-05).
    static func action(for text: String, terminalCommands: [String] = []) -> Action {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              let name = trimmed.dropFirst().split(whereSeparator: \.isWhitespace).first?.lowercased() else { return .send }
        if let native = Native(rawValue: name) { return .native(native) }
        if noteOnly.contains(name) || terminalCommands.contains(name) { return .note("/\(name) is not available in headless sessions") }
        return .send
    }

    /// The highlighted row after moving by `delta`, kept inside the list. 0 for an empty list.
    static func move(_ index: Int, by delta: Int, count: Int) -> Int {
        count == 0 ? 0 : min(max(index + delta, 0), count - 1)
    }

    /// The entry at `index`, clamped, or nil for an empty list.
    static func highlighted(_ entries: [String], index: Int) -> String? {
        entries.isEmpty ? nil : entries[move(index, by: 0, count: entries.count)]
    }
}
