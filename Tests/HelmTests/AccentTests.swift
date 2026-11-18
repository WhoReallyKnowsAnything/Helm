import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Helm

struct AccentTests {
    /// A throwaway suite, so no test touches `.standard`.
    private func store() -> AccentStore {
        let name = "gui-test-accent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AccentStore(defaults: defaults)
    }

    private func rgba(_ color: Color) -> [CGFloat] {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    private var statusColours: [[CGFloat]] {
        [Ink.waiting, Ink.running, Ink.merged, Ink.stalled].map(rgba)
    }

    @Test func theDefaultIsLimeWithDarkTextAndChoosingAnotherChangesTheAccentTokens() {
        let accents = store()
        #expect(accents.choice == .lime)
        let before = Ink.swatch(for: accents.choice)
        let lime = rgba(Color(nsColor: NSColor(srgbRed: 0xC5 / 255, green: 0xE4 / 255, blue: 0x78 / 255, alpha: 1)))
        let ground = rgba(Color(nsColor: NSColor(srgbRed: 0x0E / 255, green: 0x0E / 255, blue: 0x0F / 255, alpha: 1)))
        #expect(rgba(before.fill) == lime)
        #expect(rgba(before.onAccent) == ground)
        #expect(rgba(Ink.accent.fill) == rgba(before.fill))

        accents.choice = .purple
        let after = Ink.swatch(for: accents.choice)
        #expect(rgba(after.fill) != rgba(before.fill))
        #expect(rgba(after.text) != rgba(before.text))
    }

    @Test func statusColoursAreTheSameForEveryAccentAndNoAccentFillTakesAStatusHue() {
        let accents = store()
        let before = statusColours
        for choice in AccentChoice.allCases {
            accents.choice = choice
            #expect(statusColours == before, "\(choice) changed a status colour")
            #expect(!before.contains(rgba(Ink.swatch(for: choice).fill)), "\(choice) fill equals a status colour")
        }
    }

    @Test func aNewStoreOnTheSameSuiteRestoresTheStoredChoice() {
        let accents = store()
        accents.choice = .mint
        #expect(AccentStore(defaults: accents.defaults).choice == .mint)
    }

    @Test func anUnknownStoredValueFallsBackToTheDefault() {
        let accents = store()
        accents.defaults.set("orange", forKey: AccentStore.key)
        #expect(accents.choice == .default)
    }
}
