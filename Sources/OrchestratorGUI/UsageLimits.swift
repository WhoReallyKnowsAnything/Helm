import Foundation

/// One account-wide limit window: percent used, when it resets, and the time of the sample it came from.
struct UsageWindow: Equatable {
    let usedPercentage: Double
    let resetsAt: Date
    let sampled: Date
}

/// The 5-hour and 7-day windows (USE-01). A window is absent when no sample has carried it; one whose reset has passed stays, and the panel shows it as 0%.
struct UsageState: Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
}

enum UsageLimits {
    /// D-06: usage inside one window only rises until its reset, and idle sessions keep rewriting stale samples, so
    /// file age says nothing. Each window is the best of the held value and every entry's window: the latest
    /// `resetsAt` (a new window beats an old one, so a live window beats a reset one), then the highest percent,
    /// then the newest sample, then the pane id. No network, no
    /// credentials, no timer.
    static func update(_ held: UsageState, entries: [String: SessionStatusStore.Entry], now: Date) -> UsageState {
        UsageState(fiveHour: next(held.fiveHour, entries, now, \.fiveHour),
                   sevenDay: next(held.sevenDay, entries, now, \.sevenDay))
    }

    private static func next(_ held: UsageWindow?, _ entries: [String: SessionStatusStore.Entry], _ now: Date,
                             _ window: KeyPath<SessionStatusFold, SessionStatusFold.RawWindow?>) -> UsageWindow? {
        var candidates = entries.compactMap { path, entry in
            usage(entry.fold[keyPath: window], sampled: entry.modified).map { (id: path, window: $0) }
        }
        if let held { candidates.append((id: "", window: held)) }
        // The log path is the last tie-break, so the result does not depend on dictionary order.
        return candidates
            .max { ($0.window.resetsAt, $0.window.usedPercentage, $0.window.sampled, $0.id)
                 < ($1.window.resetsAt, $1.window.usedPercentage, $1.window.sampled, $1.id) }?.window
    }

    /// `utilization` is a 0 to 1 fraction and `resetsAt` is epoch seconds (status-limits fixture). The log is untrusted,
    /// so the percent is held to 0...100.
    private static func usage(_ window: SessionStatusFold.RawWindow?, sampled: Date) -> UsageWindow? {
        guard let window else { return nil }
        return UsageWindow(usedPercentage: min(max(window.utilization * 100, 0), 100),
                           resetsAt: Date(timeIntervalSince1970: window.resetsAt), sampled: sampled)
    }
}
