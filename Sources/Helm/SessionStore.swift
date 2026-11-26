import Foundation

/// What one tmux refresh produced.
enum TmuxOutcome: Equatable {
    case listed(sessions: String, windows: String)
    /// "no server running" or "error connecting": normal after the watchdog stops the whole server (D-12).
    case noServer
    /// Missing tmux, timeout or any other failure. The store keeps its last good data.
    case failed(String)
}

/// Runs the two list commands on the default server only (D-08). It changes no tmux state.
enum TmuxRunner {
    static let timeout: TimeInterval = 5

    static func live(socket: String? = socket) -> TmuxOutcome {
        guard let tmux = OrchestratorPaths.tmuxPath() else {
            return .failed("tmux not found in \(OrchestratorPaths.searchPath)")
        }
        switch run(tmux, ["list-sessions", "-F", SessionListing.sessionsFormat], socket) {
        case .noServer: return .noServer
        case .failed(let text): return .failed(text)
        case .ok(let sessions):
            switch run(tmux, ["list-windows", "-a", "-F", SessionListing.windowsFormat], socket) {
            case .noServer: return .noServer
            case .failed(let text): return .failed(text)
            case .ok(let windows): return .listed(sessions: sessions, windows: windows)
            }
        }
    }

    /// A private tmux server for this launch, read once. Unset or empty: the default server.
    static let socket: String? = ProcessInfo.processInfo.environment["ORCH_TMUX_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }

    /// Every tmux argument list in the app goes through here.
    static func args(_ args: [String], socket: String? = socket) -> [String] {
        (socket.map { ["-L", $0] } ?? []) + args
    }

    /// PATH, HOME and a UTF-8 LANG only. No TMUX, no TMUX_TMPDIR. Without UTF-8, tmux prints `_` for
    /// non-ASCII bytes in format output. `ORCH_TMUX_SOCKET` only when set, for the orchestrator scripts.
    static func environment(socket: String? = socket) -> [String: String] {
        var env = ["PATH": OrchestratorPaths.searchPath, "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
        if let socket { env["ORCH_TMUX_SOCKET"] = socket }
        return env
    }

    static func isNoServer(_ stderr: String) -> Bool {
        stderr.contains("no server running") || stderr.contains("error connecting")
    }

    private enum Run { case ok(String), noServer, failed(String) }

    private static func run(_ tmux: String, _ args: [String], _ socket: String?) -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = TmuxRunner.args(args, socket: socket)
        process.environment = environment(socket: socket)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return .failed("tmux did not start: \(error)") }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        watchdog.cancel()
        if process.terminationReason == .uncaughtSignal { return .failed("tmux timed out") }
        if process.terminationStatus == 0 { return .ok(output) }
        if isNoServer(errorText) { return .noServer }
        return .failed("tmux \(args[0]) failed: \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

/// The single tmux snapshot (D-04). Later phases read windows from it and add no second call.
struct TmuxSnapshot: Equatable {
    var sessions: [SessionEntry] = []
    var windows: [WindowEntry] = []
    var rows: [SessionRow] = []
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var snapshot = TmuxSnapshot()
    @Published private(set) var failure: String?
    /// Raised each time a refresh completes, so a view can follow the 2 s refresh even when the snapshot did not change.
    @Published private(set) var tick = 0

    var rows: [SessionRow] { snapshot.rows }

    private let runner: @Sendable () -> TmuxOutcome
    private var refreshing = false
    private var timer: Timer?

    init(runner: @escaping @Sendable () -> TmuxOutcome = { TmuxRunner.live() }) {
        self.runner = runner
    }

    /// Refresh now, then every 2 seconds (D-04). This is the only poll in the app.
    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// A call while the previous refresh still runs does nothing.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let interval = Perf.signposter.beginInterval("refresh")
        defer { Perf.signposter.endInterval("refresh", interval) }
        let runner = self.runner
        // The parse and the rows (which call realpath) run off the main actor, with the runner.
        let (outcome, listed) = await Task.detached { () -> (TmuxOutcome, TmuxSnapshot) in
            let outcome = runner()
            guard case .listed(let sessionsText, let windowsText) = outcome else { return (outcome, TmuxSnapshot()) }
            let sessions = SessionListing.parseSessions(sessionsText)
            let windows = SessionListing.parseWindows(windowsText)
            return (outcome, TmuxSnapshot(sessions: sessions, windows: windows,
                                          rows: SessionListing.rows(sessions: sessions, windows: windows)))
        }.value
        switch outcome {
        case .listed:
            if snapshot != listed { snapshot = listed }
            failure = nil
        case .noServer:
            if snapshot != TmuxSnapshot() { snapshot = TmuxSnapshot() }
            failure = nil
        case .failed(let text):
            failure = text
        }
        tick += 1
    }
}
