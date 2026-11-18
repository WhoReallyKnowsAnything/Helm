import AppKit
import SwiftUI
import Testing
@testable import Helm

@MainActor
@Suite struct EditorDiffViewTests {
    private func colours(_ view: some View, dark: Bool) throws -> Set<[UInt8]> {
        let size = CGSize(width: 400, height: 200)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var seen = Set<[UInt8]>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert([UInt8(c.redComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.blueComponent * 255)])
            }
        }
        return seen
    }

    /// Colour-space conversion in the render can move a channel by a step or two.
    private func has(_ seen: Set<[UInt8]>, _ want: [UInt8]) -> Bool {
        seen.contains { got in zip(got, want).allSatisfy { abs(Int($0) - Int($1)) <= 3 } }
    }

    private func rgb(_ color: Color, dark: Bool) -> [UInt8] {
        var out: [UInt8] = []
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            out = [UInt8(c.redComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.blueComponent * 255)]
        }
        return out
    }

    @Test func addedAndRemovedFillsAreDrawnAndDifferFromEmpty() throws {
        let blocks = [DiffBlock(path: nil, lines: [DiffLine(kind: .unchanged, text: "keep"),
                                                   DiffLine(kind: .removed, text: "old"),
                                                   DiffLine(kind: .added, text: "new")])]
        for dark in [false, true] {
            let drawn = try colours(EditorDiffView(blocks: blocks), dark: dark)
            #expect(has(drawn, rgb(Ink.diffAddedFill, dark: dark)))
            #expect(has(drawn, rgb(Ink.diffRemovedFill, dark: dark)))
            let empty = try colours(EditorDiffView(blocks: []), dark: dark)
            #expect(empty != drawn)
        }
    }
}
