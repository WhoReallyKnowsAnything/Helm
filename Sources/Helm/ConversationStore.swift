import Foundation

/// Follows one out log and publishes the folded conversation (D-01, D-06). Reads from byte 0 on creation,
/// then again on every file-change event in the log's folder. Modelled on `WorkerStore`.
@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var items: [ConversationItem] = []
    @Published private(set) var slashCommands: [String] = []
    @Published private(set) var skills: [String] = []
    @Published private(set) var cwd = ""
    @Published private(set) var sessionId: String?
    @Published private(set) var mcpServers: [McpServer] = []
    @Published private(set) var subagents: [Subagent] = []
    @Published private(set) var terminalSlashCommands: [String] = []
    @Published private(set) var turnRunning = false
    /// When the running turn started: the log timestamp, else the app clock at first sight. Nil when idle.
    @Published private(set) var turnStartedAt: Date?
    /// Sent messages not yet replayed in the log, shown at once as user rows.
    @Published private(set) var pending: [ConversationItem] = []
    private var echoed = 0
    private var clearCount = 0
    private var folded: [Subagent] = []
    private(set) var ended = false

    /// A session that is gone cannot finish its subagents, so none counts as running.
    func setEnded(_ value: Bool) {
        ended = value
        publishSubagents()
    }

    private func publishSubagents() {
        let shown = ended ? folded.map { var agent = $0; agent.running = false; return agent } : folded
        if subagents != shown { subagents = shown }
    }

    /// Touched only on `queue`.
    private final class Source: @unchecked Sendable {
        let reader: OutLogReader
        var parser = ConversationParser()
        init(path: String) { reader = OutLogReader(path: path) }

        /// The folded state after one read, or nil when nothing changed.
        func poll() -> (parser: ConversationParser, reset: Bool)? {
            let read = reader.read()
            if read.reset { parser = ConversationParser() }
            guard read.reset || !read.lines.isEmpty else { return nil }
            parser.feed(read.lines)
            return (parser, read.reset)
        }
    }

    private let source: Source
    private let queue = DispatchQueue(label: "ConversationStore.read")
    private let path: String
    private var watcher: ProjectWatcher?
    private var logSource: DispatchSourceFileSystemObject?
    private var reading = false
    private var readAgain = false

    init(path: String) {
        self.path = path
        source = Source(path: path)
        let folder = (path as NSString).deletingLastPathComponent
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue {
            watcher = ProjectWatcher(folder: folder) { [weak self] in
                Task { @MainActor in
                    self?.watchLog()
                    self?.requestRead()
                }
            }
        }
        watchLog()
        requestRead()
    }

    deinit { logSource?.cancel() }

    /// FSEvents sends nothing for appends through a write handle the writer holds open, so watch the file itself.
    private func watchLog() {
        guard logSource == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let log = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        log.setEventHandler { [weak self, weak log] in
            MainActor.assumeIsolated {
                guard let self, let log else { return }
                if !log.data.isDisjoint(with: [.delete, .rename]) {
                    log.cancel()
                    self.logSource = nil
                    self.watchLog()
                }
                self.requestRead()
            }
        }
        log.setCancelHandler { close(fd) }
        logSource = log
        log.resume()
    }

    func requestRead() {
        if reading {
            readAgain = true
            return
        }
        reading = true
        let source = source
        queue.async { [weak self] in
            let folded = source.poll()
            Task { @MainActor in self?.finish(folded) }
        }
    }

    /// User rows in the log so far. The view reads it before a send and hands it back to `echo`.
    var userRows: Int { items.filter { if case .user = $0 { true } else { false } }.count }

    /// `after` is `userRows` from before the send: if the log already holds more, the replay beat the echo and no row is shown.
    // shortcut: a replay from another sender during the send also suppresses the echo (its own replay still shows); a replay folded into a status row (local output, cross-session) is not counted.
    func echo(_ text: String, after: Int? = nil) {
        if let after, userRows > after { return }
        echoed += 1
        pending.append(.user(id: "p\(echoed)", text: ConversationParser.skillLine(text)))
    }

    private func finish(_ result: (parser: ConversationParser, reset: Bool)?) {
        reading = false
        if let result {
            let folded = result.parser
            let users: ([ConversationItem]) -> Int = { $0.filter { if case .user = $0 { true } else { false } }.count }
            // shortcut: matched by count, not text (a skill replays as <command-message>); a replay from another sender clears a row early, then its own replay shows.
            let cleared = folded.clearCount > clearCount
            clearCount = folded.clearCount
            let replayed = result.reset || cleared ? pending.count : users(folded.items) - users(items)
            if replayed > 0 { pending.removeFirst(min(replayed, pending.count)) }
            if items != folded.items { items = folded.items }
            if slashCommands != folded.slashCommands { slashCommands = folded.slashCommands }
            if skills != folded.skills { skills = folded.skills }
            if cwd != folded.cwd { cwd = folded.cwd }
            if sessionId != folded.sessionId { sessionId = folded.sessionId }
            if mcpServers != folded.mcpServers { mcpServers = folded.mcpServers }
            self.folded = folded.subagents
            publishSubagents()
            if terminalSlashCommands != folded.terminalSlashCommands { terminalSlashCommands = folded.terminalSlashCommands }
            if turnRunning != folded.turnRunning { turnRunning = folded.turnRunning }
            // shortcut: a log without timestamps starts the count when the app first sees the turn (about a second late); upgrade if the log gains a timestamp.
            let start = folded.turnRunning ? (folded.turnStartedAt ?? turnStartedAt ?? Date()) : nil
            if turnStartedAt != start { turnStartedAt = start }
        }
        if readAgain {
            readAgain = false
            requestRead()
        }
    }
}
