import Foundation

/// Appends stream-json user lines to an inbox file (D-01): the orchestrator row of a project, or one node.
enum InboxDelivery {
    /// The cap of the orchestrator's `session_state_flatten_message` in `lib/session-state.sh`.
    static let maxLength = 200
    /// The cap for a free-text request from the Dispatch bar, in Unicode scalars. `maxLength` stays the board's cap for Pick.
    static let requestMaxLength = 2000

    /// Cleans one untrusted piece of text (a Notion title, a worker label) before a line is built from it.
    /// Newline, carriage return and tab become 1 space each. Then every control scalar goes, so an escape
    /// sequence loses its ESC byte. Replace first, so a tab never glues two words. Nil when nothing is left.
    static func clean(_ text: String, cap: Int = maxLength) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0x09: scalars.append(" ")
            case 0x00...0x1F, 0x7F: continue
            default: scalars.append(scalar)
            }
        }
        let capped = String(String(scalars).prefix(cap))
        return capped.allSatisfy(\.isWhitespace) ? nil : capped
    }

    enum Outcome: Equatable {
        case sent
        /// Nothing was typed, on purpose.
        case refused(String)
        case failed(String)
    }

    /// Appends one stream-json user line to the `dashboard` row's inbox of `base` (D-02, D-13). There is no label
    /// parameter: the app cannot message a worker. Blocks; callers run it off the main actor. `socket` is for tests.
    /// The file belongs to the orchestrator scripts, so a missing file is a failure, never created here.
    static func deliver(_ line: String, base: String, socket: String? = TmuxRunner.socket) -> Outcome {
        let folder: String
        do {
            guard let windows = try ProjectSession.liveWindows(base: base, socket: socket),
                  let dashboard = windows.first(where: { $0.name == "dashboard" }) else {
                return .failed("No orchestrator window to send to for \(base).")
            }
            folder = dashboard.path
        } catch {
            return .failed(error.localizedDescription)
        }

        if line.isEmpty || line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return .refused("The line is empty or holds a control character. Nothing was sent.")
        }

        guard let inbox = WorkerDatabase(project: folder).inboxPath(of: "dashboard"), !inbox.isEmpty else {
            return .failed("No inbox path is stored for the orchestrator of \(base).")
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": line]]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else {
            return .failed("Could not build the message.")
        }
        data.append(0x0A)

        // No O_CREAT: the orchestrator scripts own the file.
        let fd = Darwin.open(inbox, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return .failed("Could not open the inbox: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        // One write call, so two senders never interleave inside a line.
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else {
            return .failed("Could not write to the inbox: \(written < 0 ? String(cString: strerror(errno)) : "short write")")
        }
        return .sent
    }

    /// Appends a typed message to one node's inbox (D-13). The line shape matches `deliver`,
    /// but the text keeps its newlines and tabs and has no length cap. Blocks; callers run it off the main actor.
    /// The file belongs to the orchestrator scripts: no O_CREAT, so a killed node's missing inbox is a failure.
    /// `files` are dropped files: an image becomes an image block, another file its path in the text (`PromptMessage`).
    static func append(_ text: String, inbox: String, files: [URL] = []) -> InboxDelivery.Outcome {
        guard files.isEmpty ? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : true else {
            return .refused("The message is empty. Nothing was sent.")
        }
        let message: [String: Any]
        do { message = try PromptMessage.build(text: text, files: files) } catch {
            return .refused(error.localizedDescription + " Nothing was sent.")
        }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else {
            return .failed("Could not build the message.")
        }
        data.append(0x0A)

        let fd = Darwin.open(inbox, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return .failed("Could not open the inbox: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        // One write call, so two senders never interleave inside a line.
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else {
            return .failed("Could not write to the inbox: \(written < 0 ? String(cString: strerror(errno)) : "short write")")
        }
        return .sent
    }
}
