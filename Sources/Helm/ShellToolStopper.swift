import Foundation

/// Stops the processes that an interrupted session's shell tool started (D-14), in that session only.
/// `select` is pure: parsed `ps` rows in, the rows to stop out. `stop` is the thin runner around it.
enum ShellToolStopper {
    struct Row: Equatable {
        let pid: Int32
        let ppid: Int32
        let pgid: Int32
        /// The `lstart` text with its spaces collapsed, as `GateHoldReader.hookIsLive` compares it.
        let started: String
        let args: String
    }

    private static let rowPattern = try! NSRegularExpression(
        pattern: #"^\s*(\d+)\s+(\d+)\s+(\d+)\s+([A-Z][a-z]{2}\s+[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.*)$"#)

    /// One row per line of `ps -axww -o pid=,ppid=,pgid=,lstart=,args=`. A line that does not parse is skipped.
    static func parse(_ text: String) -> [Row] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let line = String(line)
            let whole = NSRange(line.startIndex..., in: line)
            guard let m = rowPattern.firstMatch(in: line, range: whole) else { return nil }
            func group(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
            guard let pid = Int32(group(1)), let ppid = Int32(group(2)), let pgid = Int32(group(3)) else { return nil }
            let started = group(4).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return Row(pid: pid, ppid: ppid, pgid: pgid, started: started, args: group(5))
        }
    }

    /// The rows to stop. Empty unless the inbox has exactly one `tail -n +1 -f <inbox>` row with exactly one `claude -p`
    /// row in its process group. Targets: a group leader whose parent is the lean-ctx spawn-helper (a child of the lean-ctx
    /// server, a child of that claude), or a direct child of that claude whose args carry Claude's `pwd -P >| ` wrapper.
    /// Each target brings all its descendants. A PID that appears in more than one row is never used.
    static func select(_ parsed: [Row], inbox: String) -> [Row] {
        var counts: [Int32: Int] = [:]
        for row in parsed { counts[row.pid, default: 0] += 1 }
        let rows = parsed.filter { counts[$0.pid] == 1 }

        let tails = rows.filter { $0.args == "tail -n +1 -f \(inbox)" }
        guard tails.count == 1 else { return [] }
        let claudes = rows.filter { $0.pgid == tails[0].pgid && ($0.args == "claude -p" || $0.args.hasPrefix("claude -p ")) }
        guard claudes.count == 1 else { return [] }
        let claude = claudes[0]

        func words(_ row: Row) -> [String] { row.args.split(separator: " ").map(String.init) }
        func isLeanCtx(_ word: String) -> Bool { (word as NSString).lastPathComponent == "lean-ctx" }
        let servers = Set(rows.filter { $0.ppid == claude.pid && words($0).count == 1 && isLeanCtx(words($0)[0]) }.map(\.pid))
        let helpers = Set(rows.filter {
            servers.contains($0.ppid) && words($0).count == 2 && isLeanCtx(words($0)[0]) && words($0)[1] == "__spawn-helper"
        }.map(\.pid))

        let targets = rows.filter {
            (helpers.contains($0.ppid) && $0.pgid == $0.pid)
                || ($0.ppid == claude.pid && $0.args.contains("pwd -P >| "))
        }
        var picked = Set(targets.map(\.pid))
        var frontier = picked
        while !frontier.isEmpty {
            let next = Set(rows.filter { frontier.contains($0.ppid) && !picked.contains($0.pid) }.map(\.pid))
            picked.formUnion(next)
            frontier = next
        }
        return rows.filter { picked.contains($0.pid) }.sorted { $0.pid < $1.pid }
    }

    static func readPs() -> String? {
        let result = ProcessRunner.run(
            "/bin/ps", ["-axww", "-o", "pid=,ppid=,pgid=,lstart=,args="],
            environment: ["LC_ALL": "C", "TZ": "UTC"], timeout: 5)
        return result.status == 0 && !result.timedOut ? result.stdout : nil
    }

    /// One PID only, never a process group.
    static func sendSignal(_ pid: Int32, _ signal: Int32) {
        guard pid > 1 else { return }
        _ = Darwin.kill(pid, signal)
    }

    /// SIGTERM to the selected rows of the first read; 1 s later SIGKILL to each kept PID that is still alive with the same
    /// start time, whatever its parent is now. The selector does not run again: a child whose shell died is now under PID 1.
    /// Blocks; callers run it off the main actor. Returns the PIDs it signalled with SIGTERM.
    @discardableResult
    static func stop(
        inbox: String,
        readPs: () -> String? = ShellToolStopper.readPs,
        signal: (Int32, Int32) -> Void = ShellToolStopper.sendSignal,
        pause: () -> Void = { Thread.sleep(forTimeInterval: 1) }
    ) -> [Int32] {
        guard let first = readPs() else { return [] }
        let kept = select(parse(first), inbox: inbox)
        guard !kept.isEmpty else { return [] }
        for row in kept { signal(row.pid, SIGTERM) }
        pause()
        guard let second = readPs() else { return kept.map(\.pid) }
        let now = parse(second)
        for row in kept {
            let same = now.filter { $0.pid == row.pid }
            if same.count == 1, same[0].started == row.started { signal(row.pid, SIGKILL) }
        }
        return kept.map(\.pid)
    }
}
