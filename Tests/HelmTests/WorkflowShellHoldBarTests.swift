import AppKit
import SwiftUI
import Testing
@testable import Helm

/// D-03 of phase 6: the project hold bar draws above the tab content on every tab and over the editor, with the shared cards.
@MainActor
struct WorkflowShellHoldBarTests {
    private final class Calls {
        var decided: [String] = []
    }

    private static let tabs = ["board", "context", "plan", "execute", "verify", "run", "milestone"]
    private static let size = CGSize(width: 900, height: 600)

    private static func hold(_ id: String, _ label: String) -> GateHold {
        GateHold(id: id, label: label, hash: String(repeating: "a", count: 64), epoch: 100, state: .live, command: "Bash: git push \(id)")
    }

    private static func bar() -> AnyView? {
        let card = { (hold: GateHold) in
            HoldStore.Card(command: hold.command, stateLine: nil, outcome: nil, showsButtons: true, enabled: true)
        }
        return ProjectHoldBar(holds: [hold("h1", "alpha")], root: false).map {
            AnyView(ProjectHoldBarView(bar: $0, card: card, onDecide: { _, _ in }))
        }
    }

    private static func png(tab: String, editor: Bool, withBar: Bool) throws -> Data {
        let frame = WorkflowShellFrame(phases: [KitPhaseOption(id: "1", name: "One")], phase: "1", tab: tab,
                                       editor: editor ? AnyView(Color.clear) : nil, holdBar: withBar ? bar() : nil) {
            Color.clear.frame(height: 300)
        }
        let rep = try RenderSupport.render(frame, .fixed(size))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func theBarIsDrawnOnEveryTab() throws {
        for tab in Self.tabs {
            let without = try Self.png(tab: tab, editor: false, withBar: false)
            let with = try Self.png(tab: tab, editor: false, withBar: true)
            #expect(with != without, "the hold bar is not drawn on the \(tab) tab")
        }
    }

    @Test func theBarIsDrawnOverTheEditor() throws {
        let without = try Self.png(tab: "execute", editor: true, withBar: false)
        let with = try Self.png(tab: "execute", editor: true, withBar: true)
        #expect(with != without, "the hold bar is not drawn over the editor")
    }

    @Test func approveDecidesItsOwnHoldAtOnceWithNoArmingDelay() throws {
        let a = Self.hold("h1", "alpha")
        let b = Self.hold("h2", "bravo")
        let calls = Calls()
        let cards = HoldCards(
            holds: [a, b],
            card: { HoldStore.Card(command: $0.command, stateLine: nil, outcome: nil, showsButtons: true, enabled: true) },
            onDecide: { key, choice in calls.decided.append("\(key) \(choice.rawValue)") })
        #expect(cards.onScreen, "Approve must be enabled by default (D-19)")
        cards.press(a, .allow)
        #expect(calls.decided == ["\(a.key) allow"])
    }
}
