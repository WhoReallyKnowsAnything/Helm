import AppKit
import SwiftUI
import Testing
@testable import Helm

/// Offscreen rendering for the render tests (D-11): a hosting view in the dark scheme, drawn into a bitmap with no app launch.
@MainActor
enum RenderSupport {
    /// The git-ignored `screenshots/` folder. Same path logic as `SidebarRenderTests.out`.
    static let out = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("screenshots")

    enum Fit {
        /// The view gets exactly this size.
        case fixed(CGSize)
        /// The view gets its natural height. A width fixes the width, nil takes the natural width.
        case content(width: CGFloat?)
    }

    static func render<V: View>(_ view: V, _ fit: Fit) throws -> NSBitmapImageRep {
        let styled = view.background(Ink.background).preferredColorScheme(.dark)
        let host: NSHostingView<AnyView>
        switch fit {
        case .fixed(let size):
            host = NSHostingView(rootView: AnyView(styled.frame(width: size.width, height: size.height)))
            host.frame = NSRect(origin: .zero, size: size)
        case .content(let width):
            host = NSHostingView(rootView: AnyView(width.map { AnyView(styled.frame(width: $0)) } ?? AnyView(styled)))
            host.frame = NSRect(x: 0, y: 0, width: width ?? 10, height: 10)
            host.layoutSubtreeIfNeeded()
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
        }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Renders and writes `screenshots/<name>.png`.
    @discardableResult
    static func write<V: View>(_ view: V, _ fit: Fit, name: String) throws -> NSBitmapImageRep {
        let rep = try render(view, fit)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
        return rep
    }

    /// How many different colours a sample (every 5th pixel each way) of the bitmap holds.
    static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<[UInt8]>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 5) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 5) {
                var pixel = [Int](repeating: 0, count: 4)
                rep.getPixel(&pixel, atX: x, y: y)
                seen.insert(pixel.map { UInt8(truncatingIfNeeded: $0) })
            }
        }
        return seen.count
    }
}
