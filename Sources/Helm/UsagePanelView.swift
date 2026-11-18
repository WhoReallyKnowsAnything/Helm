import SwiftUI

/// The account's 5-hour and 7-day usage, from the out logs' `rate_limit_event`s (USE-01). No network call, no timer: the
/// caller passes `now` from a body that already re-runs at each tmux refresh, so a window ends at its reset time.
struct UsagePanelView: View {
    let usage: UsageState
    let now: Date
    /// The open chat's `Ctx: N%` line (D-17), drawn above the limits. Nil hides it.
    var contextText: String? = nil

    /// The line for an open chat with a known percent; nil on the tree or before the first `result`.
    static func contextLine(chatOpen: Bool, percent: Int?) -> String? {
        guard chatOpen, let percent else { return nil }
        return "Ctx: \(percent)%"
    }

    /// A window whose reset has passed did reset, so it reads 0% with no reset time. An absent window has no line.
    static func limitLines(_ usage: UsageState, now: Date) -> [String] {
        let lines = [("5h", usage.fiveHour), ("7d", usage.sevenDay)].compactMap { label, window in
            window.map { $0.resetsAt > now
                ? "\(label)  \(Int($0.usedPercentage.rounded()))% used  resets \(resetText($0.resetsAt, now: now))"
                : "\(label)  0% used" }
        }
        return lines.isEmpty ? ["usage: no data"] : lines
    }

    var body: some View {
        KitFooterLine {
            if let contextText { Text(contextText) }
            ForEach(Self.limitLines(usage, now: now), id: \.self) { Text($0) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// A time of day within the next 24 hours, else weekday plus time, in the user's locale.
    private static func resetText(_ reset: Date, now: Date) -> String {
        reset.timeIntervalSince(now) <= 24 * 3600
            ? reset.formatted(.dateTime.hour().minute())
            : reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
