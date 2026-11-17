import SwiftUI
import Testing
@testable import OrchestratorGUI

@MainActor
struct PromptBoxViewTests {
    private func box(entries: [String] = [], enabled: Bool = true, text: String = "") -> some View {
        PromptBoxView(text: .constant(text), entries: entries, enabled: enabled, message: nil, onSend: {})
    }

    @Test func anOpenMenuDrawsTallerThanAClosedOne() throws {
        let closed = try RenderSupport.render(box(), .content(width: 500))
        let open = try RenderSupport.render(box(entries: ["context", "model", "review"], text: "/"), .content(width: 500))
        #expect(open.pixelsHigh > closed.pixelsHigh)
    }

    @Test func escCallsTheClosureOncePerPressAndClosesAnOpenMenu() {
        var calls = 0
        var closed = 0
        for menuOpen in [false, true] {
            let result = PromptBoxView.escape(menuOpen: menuOpen, onEscape: { calls += 1 }, closeMenu: { closed += 1 })
            #expect(result == .handled)
        }
        #expect(calls == 2 && closed == 1)
    }

    @Test func pickingANativeOrNoteNameInterceptsAndOtherPicksFillTheDraft() {
        var taken: [String] = []
        #expect(PromptBoxView.pick("mcp", terminalCommands: [], intercept: { taken.append($0) }) == nil)
        #expect(PromptBoxView.pick("login", terminalCommands: [], intercept: { taken.append($0) }) == nil)
        #expect(taken == ["/mcp", "/login"])
        #expect(PromptBoxView.pick("context", terminalCommands: [], intercept: { taken.append($0) }) == "/context ")
        #expect(taken.count == 2)
    }

    @Test func escWithoutAClosureBehavesAsBefore() {
        #expect(PromptBoxView.escape(menuOpen: false, onEscape: nil, closeMenu: {}) == .ignored)
        var closed = 0
        #expect(PromptBoxView.escape(menuOpen: true, onEscape: nil, closeMenu: { closed += 1 }) == .handled)
        #expect(closed == 1)
    }

    @Test func theFieldClaimsFocusOnlyWhenEnabledAndNoCardHoldsIt() {
        #expect(!PromptBoxView.mayClaim(enabled: false, yieldsFocus: false, window: nil))
        #expect(!PromptBoxView.mayClaim(enabled: true, yieldsFocus: true, window: nil))
        #expect(PromptBoxView.mayClaim(enabled: true, yieldsFocus: false, window: nil))
    }

    @Test func aDisabledBoxDrawsDifferentlyAndHidesTheMenu() throws {
        let enabled = try RenderSupport.render(box(), .content(width: 500))
        let disabled = try RenderSupport.render(box(entries: ["context"], enabled: false), .content(width: 500))
        #expect(disabled.pixelsHigh == enabled.pixelsHigh)
        #expect(disabled.tiffRepresentation != enabled.tiffRepresentation)
    }
}
