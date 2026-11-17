import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OrchestratorGUI

struct TreeLayoutTests {
    private let canvas = CGSize(width: 900, height: 2000)

    private func keys(_ workers: Int) -> [String] {
        [WorkerTree.orchestratorKey] + (0..<workers).map { "w\($0)" }
    }

    /// A throwaway suite, so no test touches `.standard`.
    private func store() -> UserDefaults {
        let name = "gui-test-treelayout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test(arguments: [1, 3, 25])
    func defaultsAreDeterministicAndDoNotOverlap(workers: Int) {
        let first = TreeLayout.defaults(keys: keys(workers), canvasWidth: 900)
        #expect(first == TreeLayout.defaults(keys: keys(workers), canvasWidth: 900))
        #expect(first.count == workers + 1)
        let frames = first.values.map { CGRect(origin: $0, size: TreeLayout.nodeSize) }
        for (i, a) in frames.enumerated() {
            #expect(a.minX >= 0 && a.maxX <= 900)
            for b in frames[(i + 1)...] { #expect(!a.intersects(b)) }
        }
    }

    @Test func theOrchestratorIsOnRow0AndWorkersStartOnRow1() {
        let p = TreeLayout.defaults(keys: keys(2), canvasWidth: 900)
        #expect(p[WorkerTree.orchestratorKey]!.y == TreeLayout.margin)
        #expect(p["w0"]!.y == TreeLayout.margin + TreeLayout.nodeSize.height + TreeLayout.gap.height)
    }

    @Test func threeWorkersShareOneRowAt900() {
        let p = TreeLayout.defaults(keys: keys(3), canvasWidth: 900)
        #expect(Set(["w0", "w1", "w2"].map { p[$0]!.y }).count == 1)
        for key in ["w0", "w1", "w2"] { #expect(p[key]!.x >= 0 && p[key]!.x + TreeLayout.nodeSize.width <= 900) }
    }

    @Test func savedPositionRoundTripsAndWinsOverDefault() {
        let s = store()
        TreeLayout.save(CGPoint(x: 33, y: 77), for: "w0", project: "/p/a", in: s)
        #expect(TreeLayout.saved(project: "/p/a", in: s)["w0"] == CGPoint(x: 33, y: 77))
        let resolved = TreeLayout.resolved(keys: keys(2), project: "/p/a", canvas: canvas, in: s)
        #expect(resolved["w0"] == CGPoint(x: 33, y: 77))
        #expect(resolved["w1"] == TreeLayout.defaults(keys: keys(2), canvasWidth: 900)["w1"])
    }

    @Test func projectsAreIndependent() {
        let s = store()
        let before = TreeLayout.resolved(keys: keys(2), project: "/p/b", canvas: canvas, in: s)
        TreeLayout.save(CGPoint(x: 5, y: 5), for: "w0", project: "/p/a", in: s)
        #expect(TreeLayout.resolved(keys: keys(2), project: "/p/b", canvas: canvas, in: s) == before)
    }

    @Test func resetRemovesOnlyThatProject() {
        let s = store()
        TreeLayout.save(CGPoint(x: 5, y: 5), for: "w0", project: "/p/a", in: s)
        TreeLayout.save(CGPoint(x: 6, y: 6), for: "w0", project: "/p/b", in: s)
        TreeLayout.reset(project: "/p/a", in: s)
        #expect(TreeLayout.saved(project: "/p/a", in: s).isEmpty)
        #expect(TreeLayout.saved(project: "/p/b", in: s)["w0"] == CGPoint(x: 6, y: 6))
    }

    @Test func corruptStringGivesDefaults() {
        let s = store()
        s.set("{not json", forKey: "treeLayout:/p/a")
        #expect(TreeLayout.saved(project: "/p/a", in: s).isEmpty)
        #expect(TreeLayout.resolved(keys: keys(2), project: "/p/a", canvas: canvas, in: s)
                == TreeLayout.defaults(keys: keys(2), canvasWidth: 900))
    }

    @Test func entryForAHiddenLabelSurvivesAndReturns() {
        let s = store()
        TreeLayout.save(CGPoint(x: 11, y: 12), for: "gone", project: "/p/a", in: s)
        TreeLayout.save(CGPoint(x: 21, y: 22), for: "w0", project: "/p/a", in: s)
        #expect(TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: canvas, in: s)["gone"] == nil)
        #expect(TreeLayout.saved(project: "/p/a", in: s)["gone"] == CGPoint(x: 11, y: 12))
        let back = TreeLayout.resolved(keys: keys(1) + ["gone"], project: "/p/a", canvas: canvas, in: s)
        #expect(back["gone"] == CGPoint(x: 11, y: 12))
    }

    @Test func savedPositionOutsideCanvasResolvesInsideWithoutRewriting() {
        let s = store()
        TreeLayout.save(CGPoint(x: 5000, y: -40), for: "w0", project: "/p/a", in: s)
        let small = CGSize(width: 400, height: 300)
        let p = TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: small, in: s)["w0"]!
        #expect(CGRect(origin: .zero, size: small).contains(CGRect(origin: p, size: TreeLayout.nodeSize)))
        #expect(TreeLayout.saved(project: "/p/a", in: s)["w0"] == CGPoint(x: 5000, y: -40))
    }

    @Test func savedSizeRoundTripsPerProject() {
        let s = store()
        TreeLayout.saveSize(CGSize(width: 150, height: 90), for: "w0", project: "/p/a", in: s)
        #expect(TreeLayout.savedSizes(project: "/p/a", in: s)["w0"] == CGSize(width: 150, height: 90))
        let a = TreeLayout.sizes(keys: keys(2), project: "/p/a", in: s)
        #expect(a["w0"] == CGSize(width: 150, height: 90))
        #expect(a["w1"] == TreeLayout.nodeSize)
        #expect(TreeLayout.sizes(keys: keys(2), project: "/p/b", in: s)["w0"] == TreeLayout.nodeSize)
    }

    @Test func sizeIsClampedToTheLimits() {
        #expect(TreeLayout.clampSize(CGSize(width: 10, height: 10)) == TreeLayout.minSize)
        #expect(TreeLayout.clampSize(CGSize(width: 9000, height: 9000)) == TreeLayout.maxSize)
        let room = CGSize(width: 120, height: 5)
        #expect(TreeLayout.clampSize(CGSize(width: 300, height: 300), room: room) == CGSize(width: 120, height: TreeLayout.minSize.height))
        let s = store()
        TreeLayout.saveSize(CGSize(width: 1, height: 1), for: "w0", project: "/p/a", in: s)
        #expect(TreeLayout.sizes(keys: keys(1), project: "/p/a", in: s)["w0"] == TreeLayout.minSize)
        #expect(TreeLayout.savedSizes(project: "/p/a", in: s)["w0"] == CGSize(width: 1, height: 1))
    }

    @Test func resetClearsSizesAndPositionsOfOnlyThatProject() {
        let s = store()
        for project in ["/p/a", "/p/b"] {
            TreeLayout.save(CGPoint(x: 5, y: 5), for: "w0", project: project, in: s)
            TreeLayout.saveSize(CGSize(width: 150, height: 90), for: "w0", project: project, in: s)
        }
        TreeLayout.reset(project: "/p/a", in: s)
        #expect(TreeLayout.saved(project: "/p/a", in: s).isEmpty)
        #expect(TreeLayout.savedSizes(project: "/p/a", in: s).isEmpty)
        #expect(TreeLayout.savedSizes(project: "/p/b", in: s)["w0"] == CGSize(width: 150, height: 90))
    }

    @Test func oldPositionsOnlyEntryStillLoads() {
        let s = store()
        s.set(#"{"w0":[33,77]}"#, forKey: "treeLayout:/p/a")
        #expect(TreeLayout.saved(project: "/p/a", in: s)["w0"] == CGPoint(x: 33, y: 77))
        #expect(TreeLayout.savedSizes(project: "/p/a", in: s).isEmpty)
        #expect(TreeLayout.sizes(keys: keys(1), project: "/p/a", in: s)["w0"] == TreeLayout.nodeSize)
    }

    @Test func aBiggerNodeIsClampedByItsOwnSize() {
        let s = store()
        TreeLayout.save(CGPoint(x: 5000, y: 5000), for: "w0", project: "/p/a", in: s)
        TreeLayout.saveSize(CGSize(width: 200, height: 100), for: "w0", project: "/p/a", in: s)
        let small = CGSize(width: 400, height: 300)
        #expect(TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: small, in: s)["w0"] == CGPoint(x: 200, y: 200))
    }

    @Test func anApproveDenyPairFitsSideBySideAtTheDefaultWidth() {
        // The pair needs about 114 pt; the hold card has 5 pt of padding on each side.
        #expect(TreeLayout.nodeSize.width - 10 >= 114)
        #expect(TreeLayout.nodeSize == CGSize(width: 260, height: 170))
    }

    @Test func rowsAndColumnsStayApartByTheirGap() {
        let p = TreeLayout.defaults(keys: keys(2), canvasWidth: 600)
        #expect(p["w1"]!.x - p["w0"]!.x == TreeLayout.nodeSize.width + TreeLayout.gap.width)
        #expect(p["w0"]!.y - p[WorkerTree.orchestratorKey]!.y == TreeLayout.nodeSize.height + TreeLayout.gap.height)
    }

    @Test func theHandleSitsAtTheNodeCornerWhenThereAreNoCards() {
        #expect(TreeLayout.handleCorner(size: CGSize(width: 180, height: 120), cardsHeight: 0) == CGPoint(x: 180, y: 120))
    }

    @Test func theHandleSitsAtTheBottomRightOfTheNodeAndItsCards() {
        #expect(TreeLayout.handleCorner(size: CGSize(width: 180, height: 120), cardsHeight: 75) == CGPoint(x: 180, y: 195))
    }

    @Test func theHandleFollowsTheNodeWidthAndHeightWhileTheCardsKeepTheirHeight() {
        #expect(TreeLayout.handleCorner(size: CGSize(width: 240, height: 90), cardsHeight: 75) == CGPoint(x: 240, y: 165))
    }

    @Test func shortTitlesKeepTheDefaultWidth() {
        #expect(TreeLayout.defaultSize(titles: []) == TreeLayout.nodeSize)
        #expect(TreeLayout.defaultSize(titles: ["orchestrator-gui", "w1"]) == TreeLayout.nodeSize)
    }

    @Test func aLongTitleWidensTheDefaultToTheSmallestTwoLineWidth() {
        let title = "claude-multi-session-orchestrator-with-a-much-longer-name-and-more-words"
        let size = TreeLayout.defaultSize(titles: [title])
        #expect(size.width > TreeLayout.nodeSize.width)
        #expect(size.height == TreeLayout.nodeSize.height)
        #expect(size.width == size.width.rounded(.up))
        #expect(TreeLayout.titleLines(title, width: size.width - 10) <= 2)
        #expect(TreeLayout.titleLines(title, width: size.width - 11) >= 3)
    }

    /// One worker per row: 300 is too narrow for two nodes of 260.
    @Test func theRowBelowMovesDownByTheCardsHeightAndNothingOverlaps() {
        let plain = TreeLayout.defaults(keys: keys(2), canvasWidth: 300)
        let moved = TreeLayout.defaults(keys: keys(2), canvasWidth: 300, cardsHeights: ["w0": 240])
        #expect(moved[WorkerTree.orchestratorKey] == plain[WorkerTree.orchestratorKey])
        #expect(moved["w0"] == plain["w0"])
        #expect(moved["w1"]!.y == plain["w1"]!.y + 240)
        #expect(moved["w1"]!.x == plain["w1"]!.x)
        let size = TreeLayout.nodeSize
        let w0Stack = CGRect(origin: moved["w0"]!, size: CGSize(width: size.width, height: size.height + 240))
        let w1 = CGRect(origin: moved["w1"]!, size: size)
        #expect(!w0Stack.intersects(w1))
        // The same cards without the change would cover the node below.
        #expect(CGRect(origin: plain["w0"]!, size: CGSize(width: size.width, height: size.height + 240)).intersects(CGRect(origin: plain["w1"]!, size: size)))
    }

    @Test func aRowMovesByItsTallestCardsOnly() {
        // 600 fits two nodes per row: w0 and w1 share row 1, w2 is on row 2.
        let plain = TreeLayout.defaults(keys: keys(3), canvasWidth: 600)
        let moved = TreeLayout.defaults(keys: keys(3), canvasWidth: 600, cardsHeights: ["w0": 100, "w1": 200])
        #expect(moved["w0"] == plain["w0"] && moved["w1"] == plain["w1"])
        #expect(moved["w2"]!.y == plain["w2"]!.y + 200)
        #expect(moved["w2"]!.x == plain["w2"]!.x)
    }

    @Test func cardsUnderTheOrchestratorMoveRow1() {
        let plain = TreeLayout.defaults(keys: keys(1), canvasWidth: 300)
        let moved = TreeLayout.defaults(keys: keys(1), canvasWidth: 300, cardsHeights: [WorkerTree.orchestratorKey: 60])
        #expect(moved["w0"]!.y == plain["w0"]!.y + 60)
        #expect(moved[WorkerTree.orchestratorKey] == plain[WorkerTree.orchestratorKey])
    }

    @Test func aNodeWithNoEntryKeepsItsRowStart() {
        let plain = TreeLayout.defaults(keys: keys(2), canvasWidth: 300)
        let moved = TreeLayout.defaults(keys: keys(2), canvasWidth: 300, cardsHeights: ["w1": 500])
        #expect(moved == plain)
    }

    @Test func aSavedNodeAtTheBottomEdgeKeepsItsCardsInsideTheCanvas() {
        let s = store()
        TreeLayout.save(CGPoint(x: 5000, y: 5000), for: "w0", project: "/p/a", in: s)
        TreeLayout.save(CGPoint(x: 5000, y: 5000), for: "w1", project: "/p/a", in: s)
        let small = CGSize(width: 400, height: 300)
        let size = TreeLayout.nodeSize
        let withCards = TreeLayout.resolved(keys: keys(2), project: "/p/a", canvas: small, cardsHeights: ["w0": 75], in: s)
        #expect(withCards["w0"] == CGPoint(x: 140, y: 300 - 170 - 75))
        #expect(CGRect(origin: withCards["w0"]!, size: CGSize(width: size.width, height: size.height + 75)).maxY <= small.height)
        // The other node has no entry, so it is clamped as before.
        #expect(withCards["w1"] == CGPoint(x: 140, y: 130))
        let without = TreeLayout.resolved(keys: keys(2), project: "/p/a", canvas: small, in: s)
        #expect(without["w0"] == CGPoint(x: 140, y: 130))
        let tooTall = TreeLayout.resolved(keys: keys(2), project: "/p/a", canvas: small, cardsHeights: ["w0": 400], in: s)
        #expect(tooTall["w0"]!.y == 0)
        // The clamp never rewrites the saved value.
        #expect(TreeLayout.saved(project: "/p/a", in: s)["w0"] == CGPoint(x: 5000, y: 5000))
    }

    @Test func clampTakesTheCardsHeightOfTheNode() {
        let canvas = CGSize(width: 400, height: 300)
        #expect(TreeLayout.clamp(CGPoint(x: 0, y: 999), to: canvas).y == 130)
        #expect(TreeLayout.clamp(CGPoint(x: 0, y: 999), to: canvas, cardsHeight: 75).y == 55)
    }

    @Test func anUnsavedDefaultWithCardsIsClampedAndOneWithoutCardsIsNot() {
        let s = store()
        let small = CGSize(width: 400, height: 300)
        let plain = TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: small, in: s)
        #expect(plain["w0"] == TreeLayout.defaults(keys: keys(1), canvasWidth: 400)["w0"])
        #expect(plain["w0"]!.y == 232)
        let withCards = TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: small, cardsHeights: ["w0": 75], in: s)
        #expect(withCards["w0"]!.y == 55)
        #expect(withCards["w0"]!.y + 170 + 75 <= small.height)
        // A default that already fits is returned unchanged.
        let tall = CGSize(width: 400, height: 2000)
        #expect(TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: tall, cardsHeights: ["w0": 75], in: s)["w0"]
                == TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: tall, in: s)["w0"])
    }

    /// The cards stack of "w0" sits under a 260 x 170 node: x from the node's x, y from the node's y + 170.
    private func onScreen(_ at: CGPoint, cards: CGFloat?, other: (CGPoint, CGFloat)? = nil) -> Bool {
        var positions = ["w0": at]
        var heights: [String: CGFloat] = [:]
        if let cards { heights["w0"] = cards }
        if let other { positions["w1"] = other.0; heights["w1"] = other.1 }
        return TreeLayout.cardsOnScreen(key: "w0", positions: positions, sizes: [:], cardsHeights: heights, canvas: CGSize(width: 600, height: 600))
    }

    @Test func cardsAreOnScreenOnlyWhenFullyInsideTheCanvas() {
        #expect(onScreen(CGPoint(x: 10, y: 10), cards: 100))
        // The stack starts at y 180, so 420 ends exactly on the bottom edge and 421 is one point past it.
        #expect(onScreen(CGPoint(x: 10, y: 10), cards: 420))
        #expect(!onScreen(CGPoint(x: 10, y: 10), cards: 421))
        // 340 + 260 ends exactly on the right edge.
        #expect(onScreen(CGPoint(x: 340, y: 10), cards: 100))
        #expect(!onScreen(CGPoint(x: 341, y: 10), cards: 100))
        #expect(onScreen(CGPoint(x: 0, y: 10), cards: 100))
        #expect(!onScreen(CGPoint(x: -1, y: 10), cards: 100))
        // The stack starts at y + 170, so y = -170 is its top edge and -171 is one point above it.
        #expect(onScreen(CGPoint(x: 10, y: -170), cards: 100))
        #expect(!onScreen(CGPoint(x: 10, y: -171), cards: 100))
    }

    @Test func noMeasuredHeightIsNotOnScreen() {
        #expect(!onScreen(CGPoint(x: 10, y: 10), cards: nil))
        #expect(!onScreen(CGPoint(x: 10, y: 10), cards: 0))
    }

    @Test func overlappingCardStacksAreNotOnScreenAndTouchingOnesAre() {
        // w0's stack is x 10...270, y 180...280. w1's node at (100, 100) puts its stack at y 270...370: 10 points of overlap.
        #expect(!onScreen(CGPoint(x: 10, y: 10), cards: 100, other: (CGPoint(x: 100, y: 100), 100)))
        // At y 110 the stack starts at 280: it touches and does not overlap.
        #expect(onScreen(CGPoint(x: 10, y: 10), cards: 100, other: (CGPoint(x: 100, y: 110), 100)))
        // Far apart, and a second node with no cards.
        #expect(onScreen(CGPoint(x: 10, y: 10), cards: 100, other: (CGPoint(x: 300, y: 10), 100)))
        #expect(onScreen(CGPoint(x: 10, y: 10), cards: 100, other: (CGPoint(x: 100, y: 100), 0)))
    }

    @Test func widerDefaultsKeepNodesApartAndSizesFollowTheDefault() {
        let wide = CGSize(width: 300, height: 120)
        let first = TreeLayout.defaults(keys: keys(5), canvasWidth: 360, nodeSize: wide)
        let frames = first.values.map { CGRect(origin: $0, size: wide) }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] { #expect(!a.intersects(b)) }
        }
        let s = store()
        TreeLayout.saveSize(CGSize(width: 90, height: 60), for: "w0", project: "/p/a", in: s)
        let sizes = TreeLayout.sizes(keys: keys(2), project: "/p/a", nodeSize: wide, in: s)
        #expect(sizes["w0"] == CGSize(width: 90, height: 60))
        #expect(sizes["w1"] == wide)
    }

    // MARK: Wider prompt nodes (Plan 18)

    @Test(arguments: [1, 3, 25], [900.0, 1000.0, 400.0])
    func anEmptyWidthMapGivesTheRowsOfBefore(workers: Int, canvasWidth: Double) {
        let width = CGFloat(canvasWidth)
        let node = TreeLayout.nodeSize, gap = TreeLayout.gap, margin = TreeLayout.margin
        func centred(_ count: Int) -> [CGFloat] {
            let total = CGFloat(count) * node.width + CGFloat(count - 1) * gap.width
            let start = max(margin, (width - total) / 2)
            return (0..<count).map { start + CGFloat($0) * (node.width + gap.width) }
        }
        var expected = [WorkerTree.orchestratorKey: CGPoint(x: centred(1)[0], y: margin)]
        let names = (0..<workers).map { "w\($0)" }
        let perRow = max(1, Int((width - 2 * margin + gap.width) / (node.width + gap.width)))
        var rowY = margin
        for start in stride(from: 0, to: workers, by: perRow) {
            let row = Array(names[start..<min(start + perRow, workers)])
            rowY += node.height + gap.height
            for (key, x) in zip(row, centred(row.count)) { expected[key] = CGPoint(x: x, y: rowY) }
        }
        #expect(TreeLayout.defaults(keys: keys(workers), canvasWidth: width) == expected)
        #expect(TreeLayout.defaults(keys: keys(workers), canvasWidth: width, widths: [:]) == expected)
    }

    @Test func aRowWithOneWideNodeKeepsItsNeighboursApartAndInsideTheCanvas() {
        let widths: [String: CGFloat] = ["w1": 500]
        let positions = TreeLayout.defaults(keys: keys(3), canvasWidth: 900, widths: widths)
        let sizes = TreeLayout.widened(Dictionary(uniqueKeysWithValues: keys(3).map { ($0, TreeLayout.nodeSize) }), widths: widths, canvasWidth: 900)
        let frames = keys(3).map { CGRect(origin: positions[$0]!, size: sizes[$0]!) }
        for (i, a) in frames.enumerated() {
            #expect(a.minX >= 0 && a.maxX <= 900)
            for b in frames[(i + 1)...] where a.minY == b.minY {
                let (left, right) = a.minX < b.minX ? (a, b) : (b, a)
                #expect(right.minX - left.maxX >= TreeLayout.gap.width)
            }
        }
    }

    @Test func aCanvasThatFitsThreeDefaultNodesFitsTwoWhenOneIsWide() {
        let canvasWidth = 3 * TreeLayout.nodeSize.width + 2 * TreeLayout.gap.width + 2 * TreeLayout.margin
        let plain = TreeLayout.defaults(keys: keys(3), canvasWidth: canvasWidth)
        #expect(plain["w0"]!.y == plain["w2"]!.y)
        let wide = TreeLayout.defaults(keys: keys(3), canvasWidth: canvasWidth, widths: ["w0": 400])
        #expect(wide["w1"]!.y == wide["w0"]!.y)
        #expect(wide["w2"]!.y > wide["w0"]!.y)
    }

    @Test func aWideNodeWithCardsAtTheRightEdgeIsClampedInsideTheCanvas() {
        let s = store()
        let canvas = CGSize(width: 600, height: 2000)
        TreeLayout.save(CGPoint(x: 590, y: 50), for: "w0", project: "/p/a", in: s)
        let positions = TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: canvas, cardsHeights: ["w0": 100], widths: ["w0": 400], in: s)
        #expect(positions["w0"]!.x + 400 <= canvas.width)
        #expect(positions["w0"]!.x == 200)
    }

    @Test func theWideWidthIsNotLimitedBySavedSizeLimitAndIsNeverSaved() {
        let s = store()
        TreeLayout.saveSize(CGSize(width: 900, height: 100), for: "w0", project: "/p/a", in: s)
        let sizes = TreeLayout.sizes(keys: keys(1), project: "/p/a", in: s)
        #expect(sizes["w0"]!.width == TreeLayout.maxSize.width)
        let shown = TreeLayout.widened(sizes, widths: ["w0": 430], canvasWidth: 900)
        #expect(shown["w0"]!.width == 430)
        #expect(shown["w0"]!.height == sizes["w0"]!.height)
        #expect(TreeLayout.savedSizes(project: "/p/a", in: s)["w0"]!.width == 900)
    }

    @Test func aWidthAboveTheCapGivesTheCapAndItsCardsStayOnScreen() {
        let s = store()
        let canvas = CGSize(width: 500, height: 2000)
        let widths: [String: CGFloat] = ["w0": 900]
        let cap = canvas.width - 2 * TreeLayout.margin
        let sizes = TreeLayout.widened(TreeLayout.sizes(keys: keys(1), project: "/p/a", in: s), widths: widths, canvasWidth: canvas.width)
        #expect(sizes["w0"]!.width == cap)
        let positions = TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: canvas, cardsHeights: ["w0": 100], widths: widths, in: s)
        #expect(TreeLayout.cardsOnScreen(key: "w0", positions: positions, sizes: sizes, cardsHeights: ["w0": 100], canvas: canvas))
    }

    @Test func aCardStackTallerThanTheCanvasIsCappedSoItsButtonsStayOnScreen() {
        let s = store()
        let canvas = CGSize(width: 600, height: 500)
        let sizes = TreeLayout.sizes(keys: keys(1), project: "/p/a", in: s)
        let natural: CGFloat = 1500
        let cap = TreeLayout.cardsMaxHeight(size: sizes["w0"]!, canvas: canvas)
        #expect(cap < natural && cap > 0)
        let shown = ["w0": min(natural, cap)]
        let positions = TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: canvas, cardsHeights: shown, in: s)
        #expect(TreeLayout.cardsOnScreen(key: "w0", positions: positions, sizes: sizes, cardsHeights: shown, canvas: canvas))
        // Uncapped, the same stack is off screen.
        let tall = ["w0": natural]
        let uncapped = TreeLayout.resolved(keys: keys(1), project: "/p/a", canvas: canvas, cardsHeights: tall, in: s)
        #expect(!TreeLayout.cardsOnScreen(key: "w0", positions: uncapped, sizes: sizes, cardsHeights: tall, canvas: canvas))
    }

    @Test func aWidthBelowTheCurrentWidthOrFromANarrowCanvasChangesNothing() {
        let sizes = ["w0": CGSize(width: 300, height: 100)]
        #expect(TreeLayout.widened(sizes, widths: ["w0": 200], canvasWidth: 900) == sizes)
        #expect(TreeLayout.widened(sizes, widths: ["w0": 900], canvasWidth: 200) == sizes)
        #expect(TreeLayout.widened(sizes, widths: ["other": 900], canvasWidth: 900) == sizes)
    }

    @Test func theWideningSurvivesAResizeOverrideAndLeavesItsInputAlone() {
        var sizes = TreeLayout.sizes(keys: keys(1), project: "/p/a", in: store())
        sizes["w0"] = CGSize(width: 300, height: 150)
        let before = sizes
        let shown = TreeLayout.widened(sizes, widths: ["w0": 430], canvasWidth: 900)
        #expect(shown["w0"] == CGSize(width: 430, height: 150))
        #expect(sizes == before)
    }

    // MARK: no resize while a node is widened (D-21)

    @Test func theIncidentNodeDrawnAt900StartsNoResizeAndTheOldPathStoredTheMinimum() {
        let own = TreeLayout.nodeSize
        #expect(!TreeLayout.resizeMayStart(own: own, drawn: CGSize(width: 900, height: own.height)))
        let old = TreeLayout.clampSize(CGSize(width: own.width - 700, height: own.height))
        #expect(old.width == TreeLayout.minSize.width)
    }

    @Test func aNodeDrawnWiderStartsNoResizeWhateverTheDragOrPress() {
        let own = TreeLayout.nodeSize
        #expect(!TreeLayout.resizeMayStart(own: own, drawn: CGSize(width: 430, height: own.height)))
    }

    @Test func aNodeDrawnAtItsOwnWidthMayStartAResize() {
        let own = TreeLayout.nodeSize
        #expect(TreeLayout.resizeMayStart(own: own, drawn: own))
    }

    @Test func theSaveDecisionKeepsTheInFlightSizeWhenTheNodeIsDrawnAtIt() {
        let size = CGSize(width: 220, height: 120)
        #expect(TreeLayout.resizeSaveSize(inFlight: size, drawn: size) == size)
    }

    @Test func aDragThatCrossedBelowTheNeededWidthSavesNothing() {
        #expect(TreeLayout.resizeSaveSize(inFlight: CGSize(width: 200, height: 120), drawn: CGSize(width: 300, height: 120)) == nil)
    }

    @Test func aPromptThatArrivesMidDragSavesNothing() {
        #expect(TreeLayout.resizeSaveSize(inFlight: CGSize(width: 300, height: 120), drawn: CGSize(width: 430, height: 120)) == nil)
    }

    /// One resize gesture as `WorkerTreeView.resizeHandle` runs it: the saved size is overlaid with the in-flight size (as
    /// `resolvedSizes` does), widened by the prompt need, the start gate is asked only while nothing is in flight, and the
    /// save decision runs once at release with the need at release. `events` hold cumulative translations and the need then.
    private func gesture(saved: CGSize?, canvasWidth: CGFloat, events: [(translation: CGSize, need: CGFloat?)],
                         releaseNeed: CGFloat?, in s: UserDefaults) {
        let key = "w0", project = "/p/a"
        if let saved { TreeLayout.saveSize(saved, for: key, project: project, in: s) }
        var inFlight: (base: CGSize, size: CGSize)?
        func shown(_ need: CGFloat?) -> (own: CGSize, drawn: CGSize) {
            var sizes = TreeLayout.sizes(keys: [key], project: project, in: s)
            if let inFlight { sizes[key] = inFlight.size }
            let widths = need.map { [key: $0] } ?? [:]
            return (sizes[key]!, TreeLayout.widened(sizes, widths: widths, canvasWidth: canvasWidth)[key]!)
        }
        for event in events {
            let now = shown(event.need)
            if inFlight == nil && !TreeLayout.resizeMayStart(own: now.own, drawn: now.drawn) { continue }
            let base = inFlight?.base ?? now.own
            let grown = CGSize(width: base.width + event.translation.width, height: base.height + event.translation.height)
            inFlight = (base, TreeLayout.clampSize(grown, room: CGSize(width: canvasWidth, height: 2000)))
        }
        guard let inFlight, let size = TreeLayout.resizeSaveSize(inFlight: inFlight.size, drawn: shown(releaseNeed).drawn) else { return }
        TreeLayout.saveSize(size, for: key, project: project, in: s)
    }

    private func wide(_ width: CGFloat) -> CGSize { CGSize(width: width, height: 0) }

    @Test func theIncidentDragSavesNothingAndAPressOnAWideNodeSavesNothing() {
        let canvasWidth: CGFloat = 1100
        let s = store()
        let drawn = TreeLayout.widened(TreeLayout.sizes(keys: ["w0"], project: "/p/a", in: s), widths: ["w0": 900], canvasWidth: canvasWidth)
        #expect(drawn["w0"]!.width == 900)
        gesture(saved: nil, canvasWidth: canvasWidth, events: [(wide(-300), 900), (wide(-700), 900)], releaseNeed: 900, in: s)
        #expect(TreeLayout.savedSizes(project: "/p/a", in: s).isEmpty)
        let press = store()
        gesture(saved: nil, canvasWidth: canvasWidth, events: [(.zero, 900)], releaseNeed: 900, in: press)
        #expect(TreeLayout.savedSizes(project: "/p/a", in: press).isEmpty)
    }

    @Test func aDragThatCrossesBelowTheNeededWidthSavesNothing() {
        let s = store()
        let saved = CGSize(width: 320, height: TreeLayout.nodeSize.height)
        gesture(saved: saved, canvasWidth: 1100, events: [(wide(-20), 300), (wide(-120), 300), (wide(-130), 300)], releaseNeed: 300, in: s)
        #expect(TreeLayout.savedSizes(project: "/p/a", in: s)["w0"] == saved)
    }

    @Test func aDragOnANodeWithNoPromptStillSavesTheClampedSize() {
        let s = store()
        gesture(saved: CGSize(width: 320, height: TreeLayout.nodeSize.height), canvasWidth: 1100, events: [(wide(-100), nil)], releaseNeed: nil, in: s)
        #expect(TreeLayout.savedSizes(project: "/p/a", in: s)["w0"] == CGSize(width: 220, height: TreeLayout.nodeSize.height))
    }

    @Test func aPromptThatArrivesWhileThePointerStandsStillSavesNothing() {
        let s = store()
        let saved = CGSize(width: 320, height: TreeLayout.nodeSize.height)
        gesture(saved: saved, canvasWidth: 1100, events: [(wide(-20), nil)], releaseNeed: 430, in: s)
        #expect(TreeLayout.savedSizes(project: "/p/a", in: s)["w0"] == saved)
    }

    // MARK: no move while a node is widened (D-21 extension)

    @Test func theIncidentNodeDrawnAt900StartsNoMoveAndTheOldPathStoredX0() {
        let own = TreeLayout.nodeSize
        #expect(!TreeLayout.moveMayStart(own: own, drawn: CGSize(width: 900, height: own.height)))
        let old = TreeLayout.clamp(CGPoint(x: 300 - 700, y: 100), to: CGSize(width: 1100, height: 700), size: CGSize(width: 900, height: own.height))
        #expect(old.x == 0)
    }

    @Test func aNodeDrawnWiderStartsNoMoveWhateverTheDragOrPress() {
        let own = TreeLayout.nodeSize
        #expect(!TreeLayout.moveMayStart(own: own, drawn: CGSize(width: 430, height: own.height)))
    }

    @Test func aNodeDrawnAtItsOwnWidthMayStartAMove() {
        let own = TreeLayout.nodeSize
        #expect(TreeLayout.moveMayStart(own: own, drawn: own))
    }

    @Test func theMoveSaveDecisionKeepsTheInFlightPositionWhenTheNodeIsNotWidened() {
        let own = TreeLayout.nodeSize
        let point = CGPoint(x: 40, y: 50)
        #expect(TreeLayout.moveSavePosition(inFlight: point, own: own, drawn: own) == point)
    }

    @Test func aPromptThatArrivesMidMoveSavesNoPosition() {
        let own = TreeLayout.nodeSize
        #expect(TreeLayout.moveSavePosition(inFlight: CGPoint(x: 40, y: 50), own: own, drawn: CGSize(width: 430, height: own.height)) == nil)
    }

    /// One body gesture as `WorkerTreeView.nodeView` runs it: the node is drawn widened by the prompt need, the start gate is
    /// asked only while nothing is in flight, the in-flight position is the clamped start point plus the cumulative translation,
    /// and the save decision runs once at release with the need at release. The saved start point is (300, 100).
    private func moveGesture(canvas: CGSize, events: [(translation: CGSize, need: CGFloat?)], releaseNeed: CGFloat?, in s: UserDefaults) {
        let key = "w0", project = "/p/a", start = CGPoint(x: 300, y: 100)
        TreeLayout.save(start, for: key, project: project, in: s)
        let own = TreeLayout.sizes(keys: [key], project: project, in: s)[key]!
        func drawn(_ need: CGFloat?) -> CGSize {
            TreeLayout.widened([key: own], widths: need.map { [key: $0] } ?? [:], canvasWidth: canvas.width)[key]!
        }
        var inFlight: CGPoint?
        for event in events {
            let size = drawn(event.need)
            if inFlight == nil && !TreeLayout.moveMayStart(own: own, drawn: size) { continue }
            let moved = CGPoint(x: start.x + event.translation.width, y: start.y + event.translation.height)
            inFlight = TreeLayout.clamp(moved, to: canvas, size: size)
        }
        guard let inFlight, let point = TreeLayout.moveSavePosition(inFlight: inFlight, own: own, drawn: drawn(releaseNeed)) else { return }
        TreeLayout.save(point, for: key, project: project, in: s)
    }

    @Test func aWidenedNodeSavesNoPositionAndAnUnwidenedOneSavesTheClampedPosition() {
        let canvas = CGSize(width: 1100, height: 700)
        let start = CGPoint(x: 300, y: 100)
        let own = TreeLayout.sizes(keys: ["w0"], project: "/p/a", in: store())["w0"]!
        #expect(TreeLayout.widened(["w0": own], widths: ["w0": 900], canvasWidth: canvas.width)["w0"]!.width == 900)

        let incident = store()
        moveGesture(canvas: canvas, events: [(wide(-300), 900), (wide(-700), 900)], releaseNeed: 900, in: incident)
        #expect(TreeLayout.saved(project: "/p/a", in: incident)["w0"] == start)

        let press = store()
        moveGesture(canvas: canvas, events: [(.zero, 900)], releaseNeed: 900, in: press)
        #expect(TreeLayout.saved(project: "/p/a", in: press)["w0"] == start)

        let control = store()
        moveGesture(canvas: canvas, events: [(wide(-700), nil)], releaseNeed: nil, in: control)
        #expect(TreeLayout.saved(project: "/p/a", in: control)["w0"] == CGPoint(x: 0, y: 100))

        let late = store()
        moveGesture(canvas: canvas, events: [(wide(-100), nil)], releaseNeed: 900, in: late)
        #expect(TreeLayout.saved(project: "/p/a", in: late)["w0"] == start)
    }
}
