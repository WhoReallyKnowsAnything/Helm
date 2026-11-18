import AppKit
import SwiftUI
import Testing
@testable import Helm

/// The "Terminal craft" look (D-13a, AC7): token values, then what the parts draw.
@MainActor
struct TerminalCraftTests {
    private func rgb(_ color: Color) -> [CGFloat] {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent]
    }

    private func hex(_ value: UInt32) -> [CGFloat] {
        [CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255]
    }

    private func matches(_ color: Color, _ value: UInt32) -> Bool {
        zip(rgb(color), hex(value)).allSatisfy { abs($0 - $1) <= 1.0 / 255 + 1e-9 }
    }

    private func luminance(_ c: [CGFloat]) -> CGFloat {
        let lin = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    }

    private func contrast(_ a: Color, _ b: Color) -> CGFloat {
        let (hi, lo) = (max(luminance(rgb(a)), luminance(rgb(b))), min(luminance(rgb(a)), luminance(rgb(b))))
        return (hi + 0.05) / (lo + 0.05)
    }

    @Test func theColourTokensHoldTheD13aValues() {
        #expect(matches(Ink.background, 0x0E0E0F))
        #expect(matches(Ink.sidebar, 0x121213))
        #expect(matches(Ink.header, 0x121213))
        #expect(matches(Ink.panel, 0x161617))
        #expect(matches(Ink.selectedRow, 0x1C1C1E))
        #expect(matches(Ink.border, 0x2A2A2C))
        #expect(matches(Ink.borderStrong, 0x48484C))
        #expect(matches(Ink.text, 0xE6E6E8))
        #expect(matches(Ink.textSecondary, 0xC9C9CC))
        #expect(matches(Ink.muted, 0x9A9A9E))
        #expect(matches(Ink.dotGrid, 0x212123))
        #expect(matches(Ink.running, 0x5AA2FF))
        #expect(matches(Ink.waiting, 0x3CC8D8))
        #expect(matches(Ink.merged, 0x9AA3AD))
        #expect(matches(Ink.stalled, 0x6B727B))
        #expect(matches(Ink.accent.fill, 0xC5E478))
        #expect(matches(Ink.terminal, 0x000000))
    }

    @Test func theTextColoursReachAContrastOfFourPointFiveOnTheGround() {
        for text in [Ink.text, Ink.textSecondary, Ink.muted] {
            #expect(contrast(text, Ink.background) >= 4.5)
        }
    }

    @Test func everyTypeRoleIsFixedPitchAtTwelveOrThirteenPoints() {
        for role in KitType.allCases {
            #expect(role.nsFont.isFixedPitch, "\(role) is not fixed-pitch")
            #expect([12, 13].contains(role.nsFont.pointSize), "\(role) is \(role.nsFont.pointSize) pt")
        }
    }

    // MARK: What the parts draw

    private let pixelTolerance: CGFloat = 3 / 255

    /// The sRGB colour of the pixel at a point position, measured from the top-left of the bitmap.
    private func pixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> [CGFloat] {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))!.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent]
    }

    private func isNear(_ rgb: [CGFloat], _ value: UInt32) -> Bool {
        zip(rgb, hex(value)).allSatisfy { abs($0 - $1) <= pixelTolerance }
    }

    private func isNear(_ rgb: [CGFloat], _ color: Color) -> Bool {
        zip(rgb, self.rgb(color)).allSatisfy { abs($0 - $1) <= pixelTolerance }
    }

    @Test func aNoteDrawsTheGroundAndTheBorder() throws {
        let rep = try RenderSupport.render(KitNote(text: "note").padding(Space.lg), .content(width: nil))
        let midY = rep.size.height / 2
        #expect(isNear(pixel(rep, x: 1, y: 1), 0x0E0E0F))
        #expect(isNear(pixel(rep, x: Space.lg, y: midY), 0x2A2A2C))
    }

    @Test func aSelectedSidebarRowShowsTheAccentEdgeAndAnUnselectedRowDoesNot() throws {
        let width: CGFloat = Space.xxxl * 6
        let selected = try RenderSupport.render(
            KitSidebarRow(title: "alpha", id: "id-1", selected: true, forced: .selected, action: {}), .content(width: width))
        let plain = try RenderSupport.render(
            KitSidebarRow(title: "alpha", id: "id-1", action: {}), .content(width: width))
        let midY = selected.size.height / 2
        #expect(isNear(pixel(selected, x: 0, y: midY), Ink.accent.fill))
        #expect(isNear(pixel(selected, x: Metric.selectedEdge - 1, y: midY), Ink.accent.fill))
        #expect(isNear(pixel(selected, x: Metric.selectedEdge + Space.xs, y: midY), 0x1C1C1E))
        #expect(!isNear(pixel(plain, x: 0, y: plain.size.height / 2), Ink.accent.fill))
    }

    @Test func aRunningOrWaitingNodeCardDrawsItsStatusFillAndBorder() throws {
        let size = CGSize(width: Metric.nodeWidth, height: Metric.nodeHeight)
        func edgeAndFill(_ status: WorkerStatus?) throws -> (edge: [CGFloat], fill: [CGFloat]) {
            let rep = try RenderSupport.render(KitNodeCard(title: "node", status: status), .fixed(size))
            return (pixel(rep, x: 0, y: size.height / 2), pixel(rep, x: size.width - Space.md, y: Space.md))
        }
        let running = try edgeAndFill(.running)
        #expect(isNear(running.edge, Ink.running) && isNear(running.fill, 0x111825) && !isNear(running.fill, 0x161617))
        let waiting = try edgeAndFill(.waiting)
        #expect(isNear(waiting.edge, Ink.waiting) && isNear(waiting.fill, 0x101C21) && !isNear(waiting.fill, 0x161617))
        for status in [nil, WorkerStatus.finished, .stalled] {
            let neutral = try edgeAndFill(status)
            #expect(isNear(neutral.edge, 0x2A2A2C) && isNear(neutral.fill, 0x161617), "\(String(describing: status))")
        }
        #expect(isNear(rgb(WorkerStatus.finished.ink), 0x9AA3AD) && isNear(rgb(WorkerStatus.stalled.ink), 0x6B727B))
    }

    @Test func aPromptBarDrawsItsEdgeFillAndButtonAndShowsTextAndTheOffState() throws {
        let size = CGSize(width: 760, height: Metric.headerBar)
        func render(_ text: String, off: Bool = false) throws -> NSBitmapImageRep {
            try RenderSupport.render(KitPromptBar(text: .constant(text), action: {}).disabled(off), .fixed(size))
        }
        func png(_ rep: NSBitmapImageRep) throws -> Data { try #require(rep.representation(using: .png, properties: [:])) }
        let empty = try render("")
        #expect(isNear(pixel(empty, x: size.width / 2, y: 0), Ink.border))
        #expect(isNear(pixel(empty, x: size.width / 2, y: size.height - 2), Ink.header))
        #expect(isNear(pixel(empty, x: size.width - Space.md - Space.xs, y: size.height / 2), Ink.accent.fill))
        #expect(try png(empty) != png(render("task")))
        #expect(try png(render("task")) != png(render("task", off: true)))
    }

    @Test func theDotGridDrawsDotsOnTheGround() throws {
        let side = Metric.dotPitch * 4
        let rep = try RenderSupport.render(KitDotGrid(), .fixed(CGSize(width: side, height: side)))
        #expect(isNear(pixel(rep, x: Metric.dotPitch + Metric.dotSize / 2, y: Metric.dotPitch + Metric.dotSize / 2), 0x212123))
        #expect(isNear(pixel(rep, x: Metric.dotPitch / 2, y: Metric.dotPitch / 2), 0x0E0E0F))
    }

    @Test func aKitButtonShowsItsSourceCase() throws {
        func png(_ title: String) throws -> Data {
            let rep = try RenderSupport.render(Button(title) {}.buttonStyle(.kit).padding(Space.lg), .content(width: nil))
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        #expect(try png("Dispatch") != png("dispatch"))
        #expect(try png("Dispatch") != png("Dispatcx"))
    }

    @Test func theCornerAndFlowTokensHoldTheD13Values() {
        #expect(Metric.corner == 3)
        #expect(Motion.flowDash == 4)
        #expect(Motion.flowGap == 4)
    }
}
