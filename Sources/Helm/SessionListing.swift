import Foundation

/// One line of `tmux list-sessions`.
struct SessionEntry: Equatable {
    let name: String
    let group: String

    /// D-01: a base session has an empty group or a group equal to its own name. Never a name prefix.
    var isBase: Bool { group.isEmpty || group == name }
}

/// One line of `tmux list-windows -a`.
struct WindowEntry: Equatable {
    let session: String
    let name: String
    let path: String
    // shortcut: always nil from tmux (D-06); no reader is left, it stays only because many test fixtures pass it.
    var activity: Int? = nil
    let paneId: String
}

/// One sidebar row. The id is the tmux session name.
struct SessionRow: Equatable, Identifiable {
    let id: String
    let title: String
    /// D-17: the `dashboard` window runs in the home folder.
    var isRootSession = false
}

/// What the terminal panel shows (D-12).
enum PaneState: Equatable {
    case none, live, ended
}

/// Pure parsing of tmux output (no process is spawned here).
enum SessionListing {
    /// Nothing selected: none. The attach child exited, or the selected id left the rows: ended.
    static func paneState(selected: String?, rows: [SessionRow], processExited: Bool) -> PaneState {
        guard let selected else { return .none }
        return processExited || !rows.contains { $0.id == selected } ? .ended : .live
    }

    /// D-16, D-17: a worker's terminal is enabled only for a label that matches `^[A-Za-z0-9._][A-Za-z0-9._-]*$`
    /// (it reaches `tmux_client_attach_cmd`, and a database row is data from another process), a raw status in
    /// the live set, and a window named `label` in the base session. Raw `done` is not live. Runs no process.
    static func workerTerminalEnabled(label: String, status: String, windows: [WindowEntry], session: String) -> Bool {
        guard isWorkerLabel(label), ["running", "blocked", "stalled"].contains(status) else { return false }
        return windows.contains { $0.session == session && $0.name == label }
    }

    /// The label rule alone: `^[A-Za-z0-9._][A-Za-z0-9._-]*$`. `dashboard` passes it.
    static func isWorkerLabel(_ label: String) -> Bool {
        func word(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_") }
        guard let first = label.first else { return false }
        return word(first) && label.dropFirst().allSatisfy { word($0) || $0 == "-" }
    }

    /// tmux 3.8 prints the tab in a format string raw.
    static let sessionsFormat = "#{session_name}\t#{session_group}"
    static let windowsFormat = "#{session_name}\t#{window_name}\t#{pane_current_path}\t#{pane_id}"

    static func parseSessions(_ text: String) -> [SessionEntry] {
        fields(text, count: 2).map { SessionEntry(name: $0[0], group: $0[1]) }
    }

    static func parseWindows(_ text: String) -> [WindowEntry] {
        fields(text, count: 4).map {
            WindowEntry(session: $0[0], name: $0[1], path: $0[2], paneId: $0[3])
        }
    }

    /// One row per base session that has a window named exactly `dashboard` (D-01, D-02), in session order.
    /// A row is a root session (D-17) when that window's real path is the real path of `home`. `realpath` touches
    /// the disk, so call this off the main actor. `home` resolves once per call.
    static func rows(sessions: [SessionEntry], windows: [WindowEntry], home: String = NSHomeDirectory()) -> [SessionRow] {
        let realHome = FolderCheck.realPath(home)
        return sessions.filter(\.isBase).compactMap { session in
            guard let dashboard = windows.first(where: { $0.session == session.name && $0.name == "dashboard" })
            else { return nil }
            let isRoot = !dashboard.path.isEmpty && FolderCheck.realPath(dashboard.path) == realHome
            return SessionRow(id: session.name, title: title(path: dashboard.path, fallback: session.name), isRootSession: isRoot)
        }
    }

    /// D-03: the last component of the `dashboard` window's path, else the session name.
    static func title(path: String, fallback: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? fallback
    }

    /// Lines without exactly `count` tab-separated fields are ignored, never a crash.
    private static func fields(_ text: String, count: Int) -> [[String]] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count == count }
    }
}
