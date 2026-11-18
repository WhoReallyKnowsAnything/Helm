import AppKit
import CoreGraphics
import Foundation

/// Node positions for the worker tree (D-07). Pure: UserDefaults is a parameter, so tests never touch `.standard`.
/// Positions are top-left corners.
enum TreeLayout {
    /// Wide enough for an Approve and Deny pair side by side on a hold card (about 114 pt plus the card padding).
    static let nodeSize = CGSize(width: Metric.nodeWidth, height: Metric.nodeHeight)
    static let gap = CGSize(width: Metric.nodeGapX, height: Metric.nodeGapY)
    static let margin: CGFloat = Metric.treeMargin
    /// Room taken from the node width before the title is measured. v1's number, which `TreeLayoutTests` pin.
    private static let titlePadding: CGFloat = Metric.nodeTitlePadding

    /// Lines that `title` takes in the node card's title face when the text is `width` wide.
    static func titleLines(_ title: String, width: CGFloat) -> Int {
        let storage = NSTextStorage(string: title, attributes: [.font: KitType.title.nsFont])
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        return lines
    }

    /// One default size for the whole tree: `nodeSize`, widened so every title fits on 2 lines. Capped at `maxSize`.
    static func defaultSize(titles: [String]) -> CGSize {
        let widths = titles.map { title -> CGFloat in
            var width = nodeSize.width - titlePadding
            while width < maxSize.width - titlePadding && titleLines(title, width: width) > 2 { width += 1 }
            return width + titlePadding
        }
        return CGSize(width: widths.reduce(nodeSize.width, max), height: nodeSize.height)
    }

    /// Width of a node that must show at least `need` wide: the shared width `base`, or `need` capped at the canvas width
    /// minus both margins, whichever is larger. A canvas too narrow for the cap leaves `base`. No `need` leaves `base`.
    private static func ownWidth(base: CGFloat, need: CGFloat?, canvasWidth: CGFloat) -> CGFloat {
        max(base, min(need ?? base, canvasWidth - 2 * margin))
    }

    /// `sizes` with each node in `widths` made at least as wide as its capped entry. Heights are untouched and a key with
    /// no size is ignored. Run it after any resize override, so a node stays wide while its resize drag shows.
    static func widened(_ sizes: [String: CGSize], widths: [String: CGFloat], canvasWidth: CGFloat) -> [String: CGSize] {
        var out = sizes
        for (key, need) in widths {
            guard let size = sizes[key] else { continue }
            out[key] = CGSize(width: ownWidth(base: size.width, need: need, canvasWidth: canvasWidth), height: size.height)
        }
        return out
    }

    /// Default positions: the orchestrator on row 0, then the workers in the given order, each row centred as a group.
    /// A worker row wraps when it would be wider than the canvas, so 10 or more workers stay reachable.
    /// `keys` holds every node key, in model order. `nodeSize` is the default node size (`defaultSize(titles:)`).
    /// `widths` holds the width a node needs at least; a node with no entry has the shared width.
    /// `cardsHeights` is the measured height of the hold cards under each node. The gap below a row is the normal gap plus
    /// the tallest cards in that row, so a card never covers the node below it. A node with no entry adds nothing.
    static func defaults(keys: [String], canvasWidth: CGFloat, nodeSize: CGSize = TreeLayout.nodeSize,
                         cardsHeights: [String: CGFloat] = [:], widths: [String: CGFloat] = [:]) -> [String: CGPoint] {
        func width(_ key: String) -> CGFloat { ownWidth(base: nodeSize.width, need: widths[key], canvasWidth: canvasWidth) }
        func rowWidth(_ row: [String]) -> CGFloat { row.reduce(CGFloat(row.count - 1) * gap.width) { $0 + width($1) } }
        func place(_ row: [String], y: CGFloat, into out: inout [String: CGPoint]) {
            var x = max(margin, (canvasWidth - rowWidth(row)) / 2)
            for key in row {
                out[key] = CGPoint(x: x, y: y)
                x += width(key) + gap.width
            }
        }
        var out: [String: CGPoint] = [:]
        var rowY = margin
        place([WorkerTree.orchestratorKey], y: rowY, into: &out)
        var rowCards = cardsHeights[WorkerTree.orchestratorKey] ?? 0
        var rows: [[String]] = []
        for key in keys where key != WorkerTree.orchestratorKey {
            if let last = rows.last, rowWidth(last + [key]) <= canvasWidth - 2 * margin {
                rows[rows.count - 1].append(key)
            } else {
                rows.append([key])
            }
        }
        for row in rows {
            rowY += nodeSize.height + gap.height + rowCards
            place(row, y: rowY, into: &out)
            rowCards = row.map { cardsHeights[$0] ?? 0 }.max() ?? 0
        }
        return out
    }

    /// Sizes live beside the positions, under a sibling key, so an old positions-only entry still loads.
    private static func storageKey(_ project: String) -> String { "treeLayout:" + project }
    private static func sizeKey(_ project: String) -> String { "treeSize:" + project }

    /// A string that is missing, corrupt or not JSON reads as "nothing saved".
    private static func load<T: Codable>(_ key: String, in store: UserDefaults) -> [String: T] {
        guard let text = store.string(forKey: key),
              let entries = try? JSONDecoder().decode([String: T].self, from: Data(text.utf8))
        else { return [:] }
        return entries
    }

    private static func write<T: Codable>(_ value: T, for node: String, under key: String, in store: UserDefaults) {
        var entries: [String: T] = load(key, in: store)
        entries[node] = value
        guard let data = try? JSONEncoder().encode(entries), let text = String(data: data, encoding: .utf8) else { return }
        store.set(text, forKey: key)
    }

    static func saved(project: String, in store: UserDefaults) -> [String: CGPoint] {
        load(storageKey(project), in: store)
    }

    /// Entries for labels that are not visible stay, so a re-dispatched label keeps its position (D-07).
    static func save(_ position: CGPoint, for key: String, project: String, in store: UserDefaults) {
        write(position, for: key, under: storageKey(project), in: store)
    }

    static func savedSizes(project: String, in store: UserDefaults) -> [String: CGSize] {
        load(sizeKey(project), in: store)
    }

    static func saveSize(_ size: CGSize, for key: String, project: String, in store: UserDefaults) {
        write(size, for: key, under: sizeKey(project), in: store)
    }

    /// Clears the project's positions and sizes.
    static func reset(project: String, in store: UserDefaults) {
        store.removeObject(forKey: storageKey(project))
        store.removeObject(forKey: sizeKey(project))
    }

    /// Smallest size that still shows the name and the status line. The largest keeps one node from filling the canvas.
    static let minSize = CGSize(width: Metric.nodeMinWidth, height: Metric.nodeMinHeight)
    static let maxSize = CGSize(width: Metric.nodeMaxWidth, height: Metric.nodeMaxHeight)

    /// `room` is the space left to the canvas edge, so a resize cannot push a node out of the canvas. The minimum wins over it.
    static func clampSize(_ size: CGSize, room: CGSize = maxSize) -> CGSize {
        CGSize(width: min(max(size.width, minSize.width), max(minSize.width, min(maxSize.width, room.width))),
               height: min(max(size.height, minSize.height), max(minSize.height, min(maxSize.height, room.height))))
    }

    /// Whether a resize may start on a node of size `own` drawn at size `drawn`: not when it is drawn wider (a prompt widened it, D-21).
    /// Asked only while no resize is in flight. Widths only, because `widened` changes only the width.
    static func resizeMayStart(own: CGSize, drawn: CGSize) -> Bool {
        drawn.width <= own.width
    }

    /// The size to save when a resize ends, or nil to save nothing: the in-flight size only if the node is drawn at exactly
    /// that size, so a size the user cannot see is never stored (D-21).
    static func resizeSaveSize(inFlight: CGSize, drawn: CGSize) -> CGSize? {
        drawn == inFlight ? inFlight : nil
    }

    /// Whether a body drag may start on a node of size `own` drawn at size `drawn`: the same rule as `resizeMayStart`, so a node
    /// a prompt widened does not move (D-21). Asked only while no move is in flight.
    static func moveMayStart(own: CGSize, drawn: CGSize) -> Bool {
        resizeMayStart(own: own, drawn: drawn)
    }

    /// The position to save when a move ends, or nil to save nothing: the in-flight position only if the node is not drawn
    /// wider than its own width at release, so a position the user cannot see is never stored (D-21).
    static func moveSavePosition(inFlight: CGPoint, own: CGSize, drawn: CGSize) -> CGPoint? {
        drawn.width > own.width ? nil : inFlight
    }

    /// Bottom-right corner of the node plus its hold cards, from the node's top-left. The cards sit under the node, as wide as it.
    static func handleCorner(size: CGSize, cardsHeight: CGFloat) -> CGPoint {
        CGPoint(x: size.width, y: size.height + cardsHeight)
    }

    /// Whether the hold cards under node `key` are on screen: their rect (the node's x, the node's bottom, the node's width and
    /// the measured `cardsHeights[key]`) lies fully inside the canvas and overlaps no other node's cards. A rect that ends exactly
    /// on an edge counts as inside, and rects that only touch do not overlap. No measured height counts as not on screen.
    static func cardsOnScreen(key: String, positions: [String: CGPoint], sizes: [String: CGSize], cardsHeights: [String: CGFloat],
                              canvas: CGSize) -> Bool {
        func stack(_ key: String) -> CGRect? {
            guard let origin = positions[key], let height = cardsHeights[key], height > 0 else { return nil }
            let size = sizes[key] ?? nodeSize
            return CGRect(x: origin.x, y: origin.y + size.height, width: size.width, height: height)
        }
        guard let mine = stack(key) else { return false }
        // The slack absorbs the rounding of a measured height, so a card clamped onto the edge still counts as inside.
        let slack = Metric.onScreenSlack
        guard mine.minX >= -slack, mine.minY >= -slack, mine.maxX <= canvas.width + slack, mine.maxY <= canvas.height + slack else { return false }
        return !cardsHeights.keys.contains { other in
            guard other != key, let rect = stack(other) else { return false }
            return mine.minX < rect.maxX - slack && rect.minX < mine.maxX - slack
                && mine.minY < rect.maxY - slack && rect.minY < mine.maxY - slack
        }
    }

    /// Saved size (clamped to the limits) or else the default size, for every key.
    static func sizes(keys: [String], project: String, nodeSize: CGSize = TreeLayout.nodeSize, in store: UserDefaults) -> [String: CGSize] {
        let saved = savedSizes(project: project, in: store)
        return keys.reduce(into: [:]) { out, key in out[key] = saved[key].map { clampSize($0) } ?? nodeSize }
    }

    /// Saved position (clamped into the canvas) or else the default. The clamp never rewrites the saved value.
    /// A default is clamped only for a node that has hold cards, so its cards stay on the canvas. A default of a node without
    /// cards is not clamped: clamping a tall default grid into a short canvas would stack nodes on each other. In a canvas too
    /// short for the widened grid a node with cards can overlap the row above: the user can drag it apart, but cannot reach a card off the canvas.
    static func resolved(keys: [String], project: String, canvas: CGSize, nodeSize: CGSize = TreeLayout.nodeSize,
                         cardsHeights: [String: CGFloat] = [:], widths: [String: CGFloat] = [:], in store: UserDefaults) -> [String: CGPoint] {
        let saved = saved(project: project, in: store)
        let nodeSizes = widened(sizes(keys: keys, project: project, nodeSize: nodeSize, in: store), widths: widths, canvasWidth: canvas.width)
        return defaults(keys: keys, canvasWidth: canvas.width, nodeSize: nodeSize, cardsHeights: cardsHeights, widths: widths).reduce(into: [:]) { out, entry in
            let size = nodeSizes[entry.key] ?? nodeSize
            let cards = cardsHeights[entry.key] ?? 0
            if let point = saved[entry.key] {
                out[entry.key] = clamp(point, to: canvas, size: size, cardsHeight: cards)
            } else {
                out[entry.key] = cards > 0 ? clamp(entry.value, to: canvas, size: size, cardsHeight: cards) : entry.value
            }
        }
    }

    /// The tallest the card stack under a node of `size` may be drawn: what is left of the canvas under the node, never less
    /// than `minCardsHeight`. A taller stack scrolls inside this height, so its buttons can reach the screen.
    static func cardsMaxHeight(size: CGSize, canvas: CGSize) -> CGFloat {
        max(minCardsHeight, canvas.height - size.height - 2 * margin)
    }

    static let minCardsHeight: CGFloat = 120

    /// Keeps the node and the hold cards under it (`cardsHeight`) inside the canvas.
    static func clamp(_ point: CGPoint, to canvas: CGSize, size: CGSize = nodeSize, cardsHeight: CGFloat = 0) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), max(0, canvas.width - size.width)),
                y: min(max(point.y, 0), max(0, canvas.height - size.height - cardsHeight)))
    }
}
