import AppKit
import SwiftUI
import Testing
@testable import Helm

@MainActor
struct SyntaxColourTests {
    private let roles: [Color] = [
        Ink.syntaxKeyword, Ink.syntaxString, Ink.syntaxComment, Ink.syntaxNumber, Ink.syntaxKey, Ink.syntaxHeading,
    ]

    private func rgb(_ color: Color) -> [CGFloat] {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent]
    }

    private func luminance(_ c: [CGFloat]) -> CGFloat {
        let lin = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    }

    @Test func everyRoleReadsOnTheGround() {
        let ground = luminance(rgb(Ink.background))
        for role in roles {
            let l = luminance(rgb(role))
            #expect((max(l, ground) + 0.05) / (min(l, ground) + 0.05) >= 4.5)
        }
    }

    @Test func noTwoRolesShareAColour() {
        let all = roles.map { rgb($0).map { Int(($0 * 255).rounded()) } }
        #expect(Set(all.map { $0.map(String.init).joined(separator: ",") }).count == roles.count)
    }
}
