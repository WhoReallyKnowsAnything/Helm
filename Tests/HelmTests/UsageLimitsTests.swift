import Foundation
import Testing
@testable import Helm

struct UsageLimitsTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A window that resets `resetsIn` seconds after `now`; `used` is a percent, the log carries it as a 0 to 1 fraction.
    struct Window {
        var used: Double?
        var resetsAt: Double?
    }

    static func window(_ used: Double, resetsIn: TimeInterval) -> Window {
        Window(used: used, resetsAt: now.timeIntervalSince1970 + resetsIn)
    }

    private static func json(_ w: Window) -> String {
        [w.used.map { "\"utilization\":\($0 / 100)" }, w.resetsAt.map { "\"resetsAt\":\($0)" }]
            .compactMap { $0 }.joined(separator: ",")
    }

    static func entry(five: Window? = nil, seven: Window? = nil, age: TimeInterval) -> SessionStatusStore.Entry {
        let windows = [five.map { "\"five_hour\":{\(json($0))}" }, seven.map { "\"seven_day\":{\(json($0))}" }]
            .compactMap { $0 }.joined(separator: ",")
        var fold = SessionStatusFold()
        fold.feed("{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{\(windows)}}}")
        return SessionStatusStore.Entry(fold: fold, modified: now.addingTimeInterval(-age))
    }

    static func update(_ entries: [String: SessionStatusStore.Entry], held: UsageState = UsageState()) -> UsageState {
        UsageLimits.update(held, entries: entries, now: now)
    }

    @Test func aUtilizationFractionBecomesAPercent() {
        let state = Self.update(["a": Self.fixtureEntry()])
        // 0.29 * 100 is 28.999999999999996 in floating point; the panel rounds it for display.
        #expect(abs((state.fiveHour?.usedPercentage ?? 0) - 29) < 1e-9)
        #expect(Self.update(["a": Self.entry(five: Self.window(140, resetsIn: 100), age: 1)]).fiveHour?.usedPercentage == 100)
    }

    /// The status-limits fixture, with the reset moved after `now`; 0.29 is the value the plan names.
    private static func fixtureEntry() -> SessionStatusStore.Entry {
        var fold = SessionStatusFold()
        fold.feed("{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{\"five_hour\":{\"utilization\":0.29,\"resetsAt\":\(now.timeIntervalSince1970 + 100)}}}}")
        return SessionStatusStore.Entry(fold: fold, modified: now)
    }

    @Test func theLatestResetWins() {
        let state = Self.update([
            "%1": Self.entry(five: Self.window(10, resetsIn: 100), seven: Self.window(1, resetsIn: 9000), age: 50),
            "%2": Self.entry(five: Self.window(20, resetsIn: 200), age: 5),
            "%3": Self.entry(five: Self.window(30, resetsIn: 300), age: 20),
        ])
        #expect(state.fiveHour?.usedPercentage == 30)
        #expect(state.fiveHour?.resetsAt == Self.now.addingTimeInterval(300))
        #expect(state.sevenDay?.usedPercentage == 1)
    }

    @Test func anOlderEntryNeverOverwritesAHeldValue() {
        let held = Self.update(["%1": Self.entry(five: Self.window(20, resetsIn: 200), age: 5)])
        let state = Self.update(["%2": Self.entry(five: Self.window(10, resetsIn: 200), age: 40)], held: held)
        #expect(state.fiveHour?.usedPercentage == 20)
        let newer = Self.update(["%2": Self.entry(five: Self.window(30, resetsIn: 500), age: 1)], held: held)
        #expect(newer.fiveHour?.usedPercentage == 30)
    }

    @Test func theHigherPercentWinsAmongEntriesWithTheSameReset() {
        let state = Self.update([
            "%0": Self.entry(five: Self.window(21, resetsIn: 200), seven: Self.window(40, resetsIn: 9000), age: 50),
            "%14": Self.entry(five: Self.window(3, resetsIn: 200), seven: Self.window(38, resetsIn: 9000), age: 1),
        ])
        #expect(state.fiveHour?.usedPercentage == 21)
        #expect(state.sevenDay?.usedPercentage == 40)
    }

    @Test func aHeldValueIsNotReplacedByANewerLowerSampleOfTheSameWindow() {
        let held = Self.update(["%0": Self.entry(five: Self.window(21, resetsIn: 200), age: 50)])
        let state = Self.update(["%14": Self.entry(five: Self.window(3, resetsIn: 200), age: 0)], held: held)
        #expect(state.fiveHour?.usedPercentage == 21)
    }

    @Test func aLaterResetBeatsAHigherPercentFromAnOlderWindow() {
        let held = Self.update(["%0": Self.entry(five: Self.window(80, resetsIn: 200), age: 50)])
        let state = Self.update(["%14": Self.entry(five: Self.window(2, resetsIn: 18_000), age: 0)], held: held)
        #expect(state.fiveHour?.usedPercentage == 2)
        #expect(state.fiveHour?.resetsAt == Self.now.addingTimeInterval(18_000))
    }

    @Test func anExpiredWindowLosesToACurrentOneEvenWithAHigherPercent() {
        let state = Self.update([
            "%0": Self.entry(five: Self.window(90, resetsIn: -10), age: 1),
            "%14": Self.entry(five: Self.window(3, resetsIn: 200), age: 50),
        ])
        #expect(state.fiveHour?.usedPercentage == 3)
    }

    @Test func aFullTieIsBrokenByTheNewestSample() {
        let state = Self.update([
            "%1": Self.entry(five: Self.window(10, resetsIn: 200), age: 50),
            "%2": Self.entry(five: Self.window(10, resetsIn: 200), age: 5),
        ])
        #expect(state.fiveHour?.sampled == Self.now.addingTimeInterval(-5))
    }

    @Test func anEntryWithoutRateLimitsKeepsTheHeldValues() {
        let held = Self.update(["%1": Self.entry(five: Self.window(20, resetsIn: 200), seven: Self.window(5, resetsIn: 9000), age: 5)])
        #expect(Self.update(["%1": Self.entry(age: 1)], held: held) == held)
        #expect(Self.update([:], held: held) == held)
    }

    @Test func aWindowAtOrPastItsResetIsKeptForThePanelToShowAsReset() {
        let atReset = Self.update(["%1": Self.entry(five: Self.window(20, resetsIn: 0), seven: Self.window(5, resetsIn: 9000), age: 5)])
        #expect(atReset.fiveHour?.resetsAt == Self.now)
        #expect(atReset.sevenDay?.usedPercentage == 5)
        let held = Self.update(["%1": Self.entry(five: Self.window(20, resetsIn: 100), age: 5)])
        let later = UsageLimits.update(held, entries: [:], now: Self.now.addingTimeInterval(100))
        #expect(later == held)
    }

    @Test func aWindowThatReturnsInAFresherEntryShowsAgain() {
        let dropped = UsageLimits.update(Self.update(["%1": Self.entry(five: Self.window(20, resetsIn: 100), age: 5)]),
                                         entries: [:], now: Self.now.addingTimeInterval(200))
        #expect(dropped.fiveHour?.usedPercentage == 20)
        let back = UsageLimits.update(dropped, entries: ["%1": Self.entry(five: Self.window(3, resetsIn: 18_000), age: 0)], now: Self.now)
        #expect(back.fiveHour?.usedPercentage == 3)
    }

    @Test func aWindowMissingEitherPartIsNotCarried() {
        let half = [Window(used: 40, resetsAt: nil), Window(used: nil, resetsAt: Self.now.timeIntervalSince1970 + 100)]
        for window in half {
            #expect(Self.update(["%1": Self.entry(five: window, age: 1)]).fiveHour == nil)
        }
    }

    @Test func anOutOfRangePercentIsHeldTo0Through100() {
        let state = Self.update(["%1": Self.entry(five: Self.window(250, resetsIn: 100), seven: Self.window(-4, resetsIn: 100), age: 1)])
        #expect(state.fiveHour?.usedPercentage == 100)
        #expect(state.sevenDay?.usedPercentage == 0)
    }
}
