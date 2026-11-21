import SwiftUI

/// Draws conversation items: user text, assistant Markdown, a collapsible line per tool call and status lines.
/// All of it is one text view (`TranscriptTextView`), so one selection can cross messages.
/// Items keep the parser's ids, so an expanded tool line stays expanded as new items arrive.
struct ConversationView: View {
    let items: [ConversationItem]
    @Environment(\.kitAccent) private var accent
    @State private var expanded: Set<String> = []
    @AppStorage(ConversationFont.familyKey) private var family = ConversationFont.defaultFamily
    @AppStorage(ConversationFont.sizeKey) private var size = ConversationFont.defaultSize

    var body: some View {
        TranscriptTextView(items: items, accent: accent, expanded: expanded, font: ConversationFont(family: family, size: size)) { id in expanded.formSymmetricDifference([id]) }
    }

    /// What the view draws: one item, or a run of consecutive tool calls under one `tools` label.
    /// A group is keyed by its first tool's id, so an expanded entry stays open as the run grows.
    enum DisplayRow: Identifiable {
        case single(ConversationItem)
        case tools(id: String, [ConversationItem])

        var id: String {
            switch self {
            case .single(let item): return item.id
            case .tools(let id, _): return id
            }
        }
    }

    static func displayRows(_ items: [ConversationItem]) -> [DisplayRow] {
        var rows: [DisplayRow] = []
        for item in items {
            // A pending call that waits on the user stays its own visible line, never inside a collapsed run.
            if case .tool(let id, let name, _, let result) = item, !(name == "AskUserQuestion" && result == nil) {
                if case .tools(let groupId, let run)? = rows.last { rows[rows.count - 1] = .tools(id: groupId, run + [item]) }
                else { rows.append(.tools(id: id, [item])) }
            } else {
                rows.append(.single(item))
            }
        }
        return rows
    }

    /// The collapsed line of a tool run: one entry per group key with its call count, in first-seen order.
    static func toolGroups(_ run: [ConversationItem]) -> [(key: String, count: Int)] {
        var groups: [(key: String, count: Int)] = []
        for case .tool(_, let name, _, _) in run {
            let key = toolGroupKey(name)
            if let index = groups.firstIndex(where: { $0.key == key }) { groups[index].count += 1 } else { groups.append((key, 1)) }
        }
        return groups
    }

    /// `mcp__<server>__<tool>` groups by `<server>`; a native tool keeps its name. A server name may hold `-` or `_`.
    static func toolGroupKey(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        return parts.count >= 2 && parts[0] == "mcp" && !parts[1].isEmpty ? parts[1] : name
    }

    /// Display only: the log text, which the effort reader parses, stays as it is.
    static func statusDisplay(_ text: String) -> String {
        for prefix in ["Set model to ", "Set effort level to "] where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)
            let tick = rest.hasPrefix("`") ? "`" : ""
            return prefix + tick + ControlPickerModel.label(String(rest.dropFirst(tick.count)))
        }
        return text
    }
}

/// The `✻ working… Ns` line above the prompt box. Draws nothing without a start time (no running turn).
/// Its left edge sits at the row label column: `Space.lg` container padding + `Space.md` row padding.
struct WorkingLine: View {
    let startedAt: Date?
    @Environment(\.kitAccent) private var accent

    static func text(elapsed: TimeInterval) -> String {
        let s = Int(max(0, elapsed))
        let units = [(s / 3600, "Hour"), (s % 3600 / 60, "Min"), (s % 60, "Sec")]
        let first = units.firstIndex { $0.0 > 0 } ?? 2
        return "working… " + units[first...].map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: " ")
    }

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                HStack(spacing: Space.sm) {
                    Text("✻").foregroundStyle(accent.text).accessibilityHidden(true)
                    Text(verbatim: Self.text(elapsed: context.date.timeIntervalSince(startedAt))).foregroundStyle(Ink.textSecondary)
                }
                .kitType(.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Space.lg + Space.md)
                .padding(.vertical, Space.xs)
            }
        }
    }
}

/// Owns the store for one out-log path. The caller keys it per node and path, so a switch rebuilds it.
/// The prompt box sits under the conversation. It is disabled when the session ended or the node has no inbox path.
struct ConversationHost: View {
    let path: String?
    var inboxPath: String?
    var ended = false
    /// The node's key in the request store and the store itself: its control state feeds the pickers and the stopper.
    var nodeKey = ""
    @ObservedObject var requests = RequestStore()
    /// What `/resume` restarts for this node; nil (a worker, or no folder) shows the worker note.
    var resume: ResumeTarget?
    /// Bumped after a relaunch, so a new store reads the rewritten out log from byte 0.
    @State private var relaunches = 0

    /// The box model for one inbox. No inbox path gives a model that fails every send.
    static func makeModel(inboxPath: String?) -> PromptBoxModel {
        PromptBoxModel(deliver: { text in
            guard let inboxPath else { return .failed("No inbox path is stored for this session.") }
            return InboxDelivery.append(text, inbox: inboxPath)
        }, deliverFiles: { text, files in
            guard let inboxPath else { return .failed("No inbox path is stored for this session.") }
            return InboxDelivery.append(text, inbox: inboxPath, files: files)
        })
    }

    var body: some View {
        if let path {
            Live(path: path, inboxPath: inboxPath, ended: ended, nodeKey: nodeKey, requests: requests,
                 relaunch: resume.map { target in { id in try await target.relaunch(id: id); relaunches += 1 } })
                .id(path + "#\(relaunches)")
        } else {
            KitNotice(text: "no out log")
        }
    }

    private struct Live: View {
        @StateObject private var store: ConversationStore
        @StateObject private var box: PromptBoxModel
        @State private var effort: String?
        @State private var controlMessage: String?
        @State private var mcpAsked = false
        @State private var showSubagents = false
        @ObservedObject var requests: RequestStore
        let canSend: Bool
        let ended: Bool
        let inboxPath: String?
        let nodeKey: String
        let relaunch: (@MainActor (String) async throws -> Void)?

        init(path: String, inboxPath: String?, ended: Bool, nodeKey: String, requests: RequestStore,
             relaunch: (@MainActor (String) async throws -> Void)?) {
            self.relaunch = relaunch
            self.inboxPath = inboxPath
            self.nodeKey = nodeKey
            self.requests = requests
            _store = StateObject(wrappedValue: ConversationStore(path: path))
            _box = StateObject(wrappedValue: requests.box(for: nodeKey, inboxPath: inboxPath))
            canSend = inboxPath != nil && !ended
            self.ended = ended
        }

        /// Runs one blocking control write off the main actor and shows a failure or refusal in the box's failure line.
        private func send(_ write: @escaping @Sendable (String) -> InboxDelivery.Outcome) {
            guard let inbox = inboxPath else { controlMessage = "No inbox path is stored for this session."; return }
            controlMessage = nil
            Task {
                let outcome = await Task.detached { write(inbox) }.value
                if case .refused(let reason) = outcome { controlMessage = reason }
                if case .failed(let reason) = outcome { controlMessage = reason }
            }
        }

        private func interrupt() {
            let id = "app-" + UUID().uuidString
            requests.noteInterrupt(nodeKey: nodeKey, id: id)
            send { ControlLineWriter.appendInterrupt(id: id, inbox: $0) }
        }

        private var pickers: ControlPickerModel {
            ControlPickerModel(
                currentModel: requests.control(for: nodeKey).model, currentEffort: effort, disabled: !canSend,
                onModel: { name in send { ControlLineWriter.appendSetModel(name, inbox: $0) } },
                onEffort: { level in effort = level; send { ControlLineWriter.appendEffort(level, inbox: $0) } },
            subagentCount: store.subagents.running.count, onSubagents: { showSubagents.toggle() })
        }

        var body: some View {
            VStack(spacing: Space.none) {
                ConversationView(items: store.items + store.pending)
                .overlay {
                    if SubagentPanel.isOpen(showSubagents, running: store.subagents.running.count) {
                        SubagentPanel(subagents: store.subagents.running, onClose: { showSubagents = false })
                    }
                }
                .onChange(of: store.subagents.running.count) { _, count in
                    showSubagents = SubagentPanel.isOpen(showSubagents, running: count)
                }
                WorkingLine(startedAt: store.turnRunning ? store.turnStartedAt : nil)
                ControlPickers(model: pickers)
                PromptBoxView(
                    text: $box.draft,
                    entries: SlashMenu.entries(slashCommands: store.slashCommands, skills: store.skills, text: box.draft),
                    enabled: canSend, message: controlMessage ?? box.message,
                    onSend: { let text = box.draft; let rows = store.userRows; Task { await box.send(text, terminalCommands: store.terminalSlashCommands); if box.sent { store.echo(text, after: rows) } } },
                    onEscape: interrupt,
                    terminalCommands: store.terminalSlashCommands,
                    onIntercept: { text in Task { await box.send(text, terminalCommands: store.terminalSlashCommands) } },
                    yieldsFocus: !requests.entries(for: nodeKey).isEmpty, shown: nodeKey + "|" + (inboxPath ?? ""),
                    attachments: box.attachments, onAttach: box.attach, onDetach: box.detach)
            }
            .onChange(of: ended, initial: true) { _, value in store.setEnded(value) }
            .onChange(of: requests.control(for: nodeKey).interrupt) {
                // D-14: once per interrupt, off the main actor, for this node's own inbox.
                guard requests.control(for: nodeKey).interrupt == .ended, let inbox = inboxPath else { return }
                Task.detached { ShellToolStopper.stop(inbox: inbox) }
            }
            .onChange(of: box.command) {
                // The list comes from init, which claude writes only on the first message, so ask the session now.
                if box.command == .mcp, canSend { mcpAsked = true; send { ControlLineWriter.appendMcpStatus(inbox: $0) } }
            }
            .sheet(item: $box.command) { command in
                CommandSheet(command: command, cwd: store.cwd, sessionId: store.sessionId, mcpServers: store.mcpServers,
                             mcpLoading: mcpAsked, relaunch: relaunch, onClose: { box.command = nil })
            }
        }
    }
}
