import AppKit
import SwiftUI
import Testing
@testable import OrchestratorGUI

/// Renders the design-kit gallery offscreen to `screenshots/kit-gallery.png` for review (AC1).
@MainActor
struct KitGalleryRenderTests {
    @Test func galleryRendersAPNG() throws {
        let rep = try RenderSupport.write(KitGallery(), .content(width: 960), name: "kit-gallery")
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
        #expect(RenderSupport.distinctColours(rep) > 1)
    }

    /// A forced state is only real if it draws. Each part's cell, in each of its states, must differ from the same part's default cell.
    @Test func everyStateDrawsDifferentlyFromDefault() throws {
        for part in KitGallery.parts {
            #expect(part.states.contains(.normal), "\(part.name) has no default state")
            let base = try png(part, .normal)
            for state in part.states where state != .normal {
                #expect(try png(part, state) != base, "\(part.name): \(state.rawValue) draws the same as default")
            }
        }
    }

    private func png(_ part: KitPart, _ state: KitState) throws -> Data {
        let rep = try RenderSupport.render(part.cell(state).padding(Space.md), .content(width: nil))
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
