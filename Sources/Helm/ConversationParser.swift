import Foundation

/// Decoded JSON, kept as a value so tool input reaches the views untouched.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map(JSONValue.init))
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init))
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        default: self = .null
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

struct ToolResult: Equatable {
    var text: String
    var isError: Bool
}

enum ConversationItem: Equatable, Identifiable {
    case user(id: String, text: String)
    case assistant(id: String, text: String, inProgress: Bool)
    case tool(id: String, name: String, input: JSONValue, result: ToolResult?)
    /// A local command's reply, such as "Set model to …". No tags, no gutter label.
    case status(id: String, text: String)

    var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _, _), .tool(let id, _, _, _), .status(let id, _): return id
        }
    }
}

/// Folds out-log lines into conversation items (D-05). A value type with no UI: feed it lines as they
/// arrive, or start a new one after a reader reset. A malformed line or an unknown event changes nothing.
/// One `mcp_servers` entry of an `init` event.
struct McpServer: Equatable {
    var name: String
    var status: String
    var source: String
}

/// One Agent tool call and the messages the subagent itself produced (they carry the call's id as `parent_tool_use_id`).
struct Subagent: Equatable, Identifiable {
    let id: String
    var title = "Subagent"
    var type = ""
    var running = true
    var items: [ConversationItem] = []
}

struct ConversationParser: Equatable {
    private(set) var items: [ConversationItem] = []
    private(set) var subagents: [Subagent] = []
    private var children: [String: ConversationParser] = [:]
    private var taskTools: [String: String] = [:]
    /// Agent calls launched in the background: their tool_result is only the launch ack, so it must not end them.
    private var backgrounded: Set<String> = []
    private var isChild = false
    private var toolIndex: [String: Int] = [:]
    private var textBlocks: [String: Int] = [:]
    private var counter = 0
    private(set) var sessionId: String?
    /// True once the current turn produced assistant text, so its `result` adds nothing.
    private var turnHadText = false
    /// The newest `init` event's menu sources (bare names). Empty until the first init.
    private(set) var slashCommands: [String] = []
    private(set) var skills: [String] = []
    private(set) var cwd = ""
    private(set) var mcpServers: [McpServer] = []
    private(set) var terminalSlashCommands: [String] = []
    private(set) var turnRunning = false
    /// How many times the log cleared the conversation, so the store can drop its echo rows.
    private(set) var clearCount = 0
    /// The log timestamp of the user line that started the running turn. Nil when idle or when the line has none.
    private(set) var turnStartedAt: Date?

    mutating func feed(_ lines: [String]) { lines.forEach { feed($0) } }

    mutating func feed(_ line: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return }
        if let session = object["session_id"] as? String {
            if let previous = sessionId, previous != session {
                // A new session_id is how /clear shows in the log; a --resume keeps the id (resume-live.jsonl).
                items = []; toolIndex = [:]; textBlocks = [:]; turnHadText = false
                subagents = []; children = [:]; taskTools = [:]; backgrounded = []
                turnRunning = false; turnStartedAt = nil; clearCount += 1
            }
            sessionId = session
        }
        if !["result", "system", "control_response"].contains(type), let parent = object["parent_tool_use_id"] as? String {
            foldChild(parent, type, object)
            return
        }
        switch type {
        case "system": foldSystem(object)
        case "user": foldUser(object)
        case "assistant": foldAssistant(object)
        case "stream_event": foldStream(object)
        case "result": foldResult(object)
        case "control_response": foldControlResponse(object)
        default: break
        }
    }

    /// A `set_model` success is silent in the log, so it gets its own status line. A local reply just before it already says so.
    /// An `mcp_status` success replaces the init's server list, so `/mcp` fills before the first message.
    private mutating func foldControlResponse(_ object: [String: Any]) {
        guard let response = object["response"] as? [String: Any], response["subtype"] as? String == "success" else { return }
        if let servers = (response["response"] as? [String: Any])?["mcpServers"] as? [[String: Any]] {
            mcpServers = Self.servers(servers)
            return
        }
        guard let full = (response["response"] as? [String: Any])?["model"] as? String, !full.isEmpty else { return }
        if case .status(_, let text)? = items.last, text.hasPrefix("Set model to"), text.contains(full) { return }
        let alias = ControlLineWriter.models.first { !$0.contains("[") && full.contains($0) }
        append(.status(id: nextId("l"), text: "Set model to " + (alias.map { "\($0) (\(full))" } ?? full)))
    }

    /// A subagent's own message folds like a main one, into a parser of its own, so the main items stay clean.
    private mutating func foldChild(_ parent: String, _ type: String, _ object: [String: Any]) {
        var child = children[parent] ?? { var fresh = ConversationParser(); fresh.isChild = true; return fresh }()
        switch type {
        case "user": child.foldUser(object)
        case "assistant": child.foldAssistant(object)
        case "stream_event": child.foldStream(object)
        default: return
        }
        subagents[subagent(parent)].items = child.items
        children[parent] = child
    }

    private mutating func subagent(_ id: String) -> Int {
        if let index = subagents.firstIndex(where: { $0.id == id }) { return index }
        subagents.append(Subagent(id: id))
        return subagents.count - 1
    }

    private mutating func finishSubagent(_ id: String) {
        if let index = subagents.firstIndex(where: { $0.id == id }) { subagents[index].running = false }
    }

    private mutating func foldTask(_ object: [String: Any]) {
        switch object["subtype"] as? String {
        case "task_started":
            guard let id = object["tool_use_id"] as? String, object["task_type"] as? String ?? "local_agent" == "local_agent" else { return }
            let index = subagent(id)
            if let title = object["description"] as? String { subagents[index].title = title }
            subagents[index].type = object["subagent_type"] as? String ?? ""
            if let task = object["task_id"] as? String { taskTools[task] = id }
            if object["is_backgrounded"] as? Bool == true { backgrounded.insert(id) }
        case "task_updated":
            let status = (object["patch"] as? [String: Any])?["status"] as? String
            if status == "completed", let task = object["task_id"] as? String, let id = taskTools[task] { finishSubagent(id) }
        case "task_notification":
            if let id = object["tool_use_id"] as? String { finishSubagent(id) }
        default: break
        }
    }

    private mutating func foldSystem(_ object: [String: Any]) {
        if object["subtype"] as? String == "informational",
           let outcome = object["prompt_submit_outcome"] as? [String: Any], outcome["kind"] as? String == "blocked_by_hook",
           let reason = outcome["reason"] as? String, !reason.isEmpty {
            append(.status(id: nextId("b"), text: reason))
            turnHadText = true // the closing `result` repeats the reason with a prefix
            return
        }
        guard object["subtype"] as? String == "init" else { return foldTask(object) }
        for index in subagents.indices { subagents[index].running = false }
        slashCommands = object["slash_commands"] as? [String] ?? []
        skills = object["skills"] as? [String] ?? []
        cwd = object["cwd"] as? String ?? ""
        mcpServers = Self.servers(object["mcp_servers"] as? [[String: Any]] ?? [])
        terminalSlashCommands = object["terminal_slash_commands"] as? [String] ?? []
    }

    private static func servers(_ list: [[String: Any]]) -> [McpServer] {
        list.map { McpServer(name: $0["name"] as? String ?? "", status: $0["status"] as? String ?? "", source: $0["source"] as? String ?? "") }
    }

    private var streamIndex: Int? {
        if let last = items.indices.last, case .assistant(_, _, true) = items[last] { return last }
        return nil
    }

    private mutating func foldStream(_ object: [String: Any]) {
        guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
              let piece = delta["text"] as? String else { return }
        if let index = streamIndex, case .assistant(let id, let text, _) = items[index] {
            items[index] = .assistant(id: id, text: text + piece, inProgress: true)
        } else {
            append(.assistant(id: nextId("s"), text: piece, inProgress: true))
        }
    }

    /// Drops the in-progress item: the final `assistant` event replaces it.
    private mutating func dropStream() { if let index = streamIndex { items.remove(at: index) } }

    /// Keeps interrupted streamed text as a finished item.
    private mutating func finishStream() {
        if let index = streamIndex, case .assistant(let id, let text, _) = items[index] {
            items[index] = .assistant(id: id, text: text, inProgress: false)
        }
    }

    private mutating func foldResult(_ object: [String: Any]) {
        finishStream()
        turnRunning = false
        turnStartedAt = nil
        defer { turnHadText = false }
        guard !turnHadText, let text = object["result"] as? String, !text.isEmpty else { return }
        append(.assistant(id: nextId("r"), text: text, inProgress: false))
    }

    private mutating func nextId(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)\(counter)"
    }

    private mutating func append(_ item: ConversationItem) { items.append(item) }

    private mutating func foldUser(_ object: [String: Any]) {
        let content = (object["message"] as? [String: Any])?["content"]
        let replay = object["isReplay"] as? Bool == true || isChild
        var typed: [String] = []
        if let text = content as? String {
            typed = [text]
        } else if let blocks = content as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "tool_result": pair(block)
                case "text": if let text = block["text"] as? String { typed.append(text) }
                // `PromptMessage` writes a named "[image: x.png]" text block before each image; any other image gets a bare marker.
                case "image": if typed.last?.hasPrefix("[image:") != true { typed.append("[image]") }
                default: break
                }
            }
        }
        if replay, let reply = Self.localOutput(typed.joined(separator: "\n")) {
            append(.status(id: nextId("l"), text: reply))
        } else if replay, !typed.isEmpty {
            if !turnRunning { turnStartedAt = Self.date(object["timestamp"]) }
            finishStream(); turnHadText = false; turnRunning = true
            let text = typed.joined(separator: "\n")
            if let relayed = Self.crossSession(text) {
                append(.status(id: nextId("x"), text: relayed))
            } else {
                append(.user(id: nextId("u"), text: Self.skillLine(text)))
            }
        }
    }

    /// `from <sender>: <body>` for a message another Claude session sent (the text opens with the tag, after an optional intro), else nil.
    static func crossSession(_ raw: String) -> String? {
        let intro = "Another Claude session sent a message:"
        let tag = "<cross-session-message "
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(intro) { text = String(text.dropFirst(intro.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let handBack = subagentHandBack(text) { return handBack }
        guard text.hasPrefix(tag),
              let head = text.range(of: tag), let headEnd = text.range(of: ">", range: head.upperBound..<text.endIndex),
              let close = text.range(of: "</cross-session-message>", range: headEnd.upperBound..<text.endIndex),
              let nameOpen = text.range(of: "from-name=\"", range: head.upperBound..<headEnd.lowerBound),
              let nameClose = text.range(of: "\"", range: nameOpen.upperBound..<headEnd.lowerBound) else { return nil }
        let body = text[headEnd.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return "from \(text[nameOpen.upperBound..<nameClose.lowerBound]): \(body)"
    }

    /// `from subagent <id>: <report>` for a tag-first `<agent-message from="id">` hand-back; drops the harness frame line and the report's 2-space indent.
    private static func subagentHandBack(_ text: String) -> String? {
        let tag = "<agent-message from=\""
        guard text.hasPrefix(tag),
              let idEnd = text.range(of: "\"", range: text.index(text.startIndex, offsetBy: tag.count)..<text.endIndex),
              let headEnd = text.range(of: ">", range: idEnd.upperBound..<text.endIndex),
              let close = text.range(of: "</agent-message>", range: headEnd.upperBound..<text.endIndex) else { return nil }
        let id = text[text.index(text.startIndex, offsetBy: tag.count)..<idEnd.lowerBound]
        var lines = text[headEnd.upperBound..<close.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), first.hasPrefix("[Subagent hand-back]"),
           let at = lines.firstIndex(of: first) { lines.removeSubrange(0...at) }
        let report = lines.map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
        return "from subagent \(id): \(report.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// An ISO 8601 timestamp with or without fractional seconds, else nil.
    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? plain.date(from: string)
    }

    /// The trimmed inner text of a `<local-command-stdout>` block, else nil.
    private static func localOutput(_ text: String) -> String? {
        guard let open = text.range(of: "<local-command-stdout>"),
              let close = text.range(of: "</local-command-stdout>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A skill invocation arrives as tagged text. Show it as `/name args`; any other text stays as it is.
    static func skillLine(_ text: String) -> String {
        func tag(_ name: String) -> String? {
            guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
            return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = tag("command-name") else { return text }
        let args = tag("command-args") ?? ""
        return args.isEmpty ? name : "\(name) \(args)"
    }

    private mutating func pair(_ block: [String: Any]) {
        if let useId = block["tool_use_id"] as? String, !backgrounded.contains(useId) { finishSubagent(useId) }
        guard let useId = block["tool_use_id"] as? String, let index = toolIndex[useId],
              case .tool(let id, let name, let input, _) = items[index] else { return }
        var text = ""
        if let plain = block["content"] as? String {
            text = plain
        } else if let parts = block["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        items[index] = .tool(id: id, name: name, input: input,
                             result: ToolResult(text: text, isError: block["is_error"] as? Bool == true))
    }

    private mutating func foldAssistant(_ object: [String: Any]) {
        if let source = object["local_command_source"] as? String, let reply = Self.localOutput(source) {
            append(.status(id: nextId("l"), text: reply))
            turnHadText = true // the closing `result` repeats this text
            return
        }
        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        let messageId = (message["id"] as? String) ?? nextId("a")
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !text.isEmpty else { continue }
                dropStream()
                turnHadText = true
                let position = textBlocks[messageId, default: 0]
                textBlocks[messageId] = position + 1
                append(.assistant(id: "\(messageId)#\(position)", text: text, inProgress: false))
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String,
                      toolIndex[id] == nil else { continue }
                toolIndex[id] = items.count
                append(.tool(id: id, name: name, input: JSONValue(block["input"] ?? NSNull()), result: nil))
                if !isChild, name == "Agent" || name == "Task" {
                    let index = subagent(id)
                    let input = block["input"] as? [String: Any]
                    if let title = input?["description"] as? String { subagents[index].title = title }
                    subagents[index].type = input?["subagent_type"] as? String ?? ""
                }
            default: break
            }
        }
    }
}
