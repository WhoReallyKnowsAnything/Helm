import AppKit
import SwiftUI

/// The canvas slot: the orchestrator and its visible workers, drawn as a tree.
struct WorkerTreeView: View {
    let orchestratorTitle: String
    let session: String
    /// The project folder that keys the saved node positions (D-07).
    let project: String
    /// Each node's out-log status, keyed like `WorkerTree.init(log:)`.
    let log: [String: SessionStatusStore.Entry]
    /// Passed in by ContentView as `Date()` in its body, which runs again at each 2-second tmux refresh.
    /// A stalled worker's log write time never changes, so without a changing input SwiftUI could skip this body.
    let now: Date
    /// The lines under each node (`NodeInfo`): context %, then `model · effort`, or "no data".
    let nodeInfo: [String: [String]]
    let result: WorkerRead?
    let failure: String?
    /// The selected project's classified gate holds and the blocks they covered (D-09). They only set the status text here.
    let holds: [GateHold]
    let blockCover: BlockCover
    var deadLabels: Set<String> = []
    /// The hold store's failure text, such as an unreadable `gate-holds` folder. Shown in the footer.
    let holdFailure: String?
    /// What a hold card shows and whether its buttons work, and the answer to a click. Both come from the hold store (D-06).
    let card: (GateHold) -> HoldStore.Card
    let onDecide: (_ key: String, _ choice: HoldChoice) -> Void
    let retry: () -> Void
    /// A tap on the orchestrator or a worker node. ContentView swaps the tree for that node's terminal.
    let onNodeTap: (WorkerTreeNode) -> Void
    /// The open permission requests (D-07), drawn after the hold cards. Defaults keep every existing call site as it was.
    var requests: [RequestStore.Entry] = []
    var requestCard: (RequestStore.Entry) -> RequestStore.Card = { _ in
        RequestStore.Card(command: "", stateLine: nil, outcome: nil, showsButtons: false, enabled: false)
    }
    var onRequestAnswer: (_ key: String, _ allow: Bool, _ source: RequestStore.DenySource) -> Void = { _, _, _ in }
    var questionBinding = QuestionBinding.none
    var requestStamp = 0

    /// While a drag runs, the node and its lines follow this in-memory position only. UserDefaults is written when the drag ends.
    @State private var drag: (key: String, base: CGPoint, position: CGPoint)?
    /// While a resize runs, the node and its lines follow this in-memory size only. UserDefaults is written when the drag ends.
    @State private var resize: (key: String, base: CGSize, size: CGSize)?
    /// Height of each worker's hold-card block, measured, so the resize handle can sit under the cards.
    @State private var cardHeights: [String: CGFloat] = [:]
    /// Read in `canvas` so a reset or a saved drag makes SwiftUI read UserDefaults again.
    @State private var layoutVersion = 0
    @Environment(\.appearsActive) private var appearsActive

    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    var body: some View {
        VStack(spacing: Space.none) {
            canvas
            if let failure { KitFooterLine { Text(failure) } }
            if let holdFailure { KitFooterLine { Text(holdFailure) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Ink.background
            KitDotGrid()
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let tree = tree
            let _ = layoutVersion
            let defaultSize = TreeLayout.defaultSize(titles: tree.nodes.map(\.title))
            let widths: [String: CGFloat] = [:]
            let positions = resolvedPositions(for: tree, canvas: geo.size, defaultSize: defaultSize, widths: widths)
            // `baseSizes` is the saved or resized size: the only size a resize handle starts from or saves. `sizes` is what is drawn.
            let baseSizes = resolvedSizes(for: tree, defaultSize: defaultSize)
            let sizes = TreeLayout.widened(baseSizes, widths: widths, canvasWidth: geo.size.width)
            let flow = ActiveLines.resolve(nodes: tree.nodes, edges: tree.edges, log: log, now: now)
            ZStack(alignment: .topLeading) {
                // Paused when no line animates and in an inactive window, so an idle tree redraws nothing.
                TimelineView(.animation(paused: flow.edges.isEmpty || !appearsActive)) { timeline in
                    let phase = ActiveLines.dashPhase(at: timeline.date, period: Motion.flowPeriod, cycle: Motion.flowDash + Motion.flowGap)
                    Canvas { context, _ in
                        for edge in tree.edges {
                            guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
                            let flowing = flow.edges.contains(edge)
                            var path = Path()
                            switch edge.kind {
                            case .hierarchy:
                                path.move(to: centre(from, sizes[edge.from]))
                                path.addLine(to: centre(to, sizes[edge.to]))
                                if flowing {
                                    context.stroke(path, with: .color(Ink.running), style: StrokeStyle(lineWidth: Metric.edgeWidth, dash: [Motion.flowDash, Motion.flowGap], dashPhase: -phase))
                                } else {
                                    context.stroke(path, with: .color(Ink.borderStrong), lineWidth: Metric.edgeWidth)
                                }
                            case .dependency:
                                // Bows below the nodes: neighbours on one row are only a few points apart, so a straight line would hide.
                                let a = bottom(from, sizes[edge.from]), b = bottom(to, sizes[edge.to])
                                path.move(to: a)
                                path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: max(a.y, b.y) + Metric.dependencyBow))
                                context.stroke(path, with: .color(flowing ? Ink.running : Ink.borderStrong), style: StrokeStyle(lineWidth: Metric.edgeWidth, dash: [Motion.flowDash, Motion.flowGap], dashPhase: flowing ? -phase : 0))
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
                ForEach(tree.nodes, id: \.key) { node in
                    let origin = positions[node.key] ?? .zero
                    let size = sizes[node.key] ?? TreeLayout.nodeSize
                    nodeView(node, origin: origin, size: size, own: baseSizes[node.key] ?? TreeLayout.nodeSize, canvas: geo.size)
                        .frame(width: size.width, height: size.height)
                        // Outside nodeView, so its tap and move gestures never see a press on the handle.
                        // A node with hold cards gets its handle below, at the corner of the node plus the cards.
                        .overlay(alignment: .bottomTrailing) {
                            if !hasCards(node) {
                                resizeHandle(node, origin: origin, size: baseSizes[node.key] ?? TreeLayout.nodeSize, drawn: size, canvas: geo.size)
                            }
                        }
                        .offset(x: positions[node.key]?.x ?? 0, y: positions[node.key]?.y ?? 0) // grid: ok places a node at its saved or dragged position
                }
                // Siblings of the nodes, not part of nodeView: a node has its own tap, drag and resize gestures. A hold whose
                // label has no drawn node draws nothing (D-16), because the cards come from the tree's own worker nodes.
                // The request cards sit in the same stack, after the hold cards, so one measured height covers both.
                ForEach(tree.nodes.filter { hasCards($0) }, id: \.key) { node in
                    let cards = node.kind == .worker ? holds.filter { $0.label == node.key } : []
                    let origin = positions[node.key] ?? .zero
                    let size = sizes[node.key] ?? TreeLayout.nodeSize
                    // Text under a clipped or covered card does not count as shown, so no button arms from it.
                    let onScreen = TreeLayout.cardsOnScreen(key: node.key, positions: positions, sizes: sizes,
                                                            cardsHeights: liveCardHeights(for: tree), canvas: geo.size)
                    // A stack taller than the canvas scrolls, so its Send button can reach the screen.
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            if !cards.isEmpty {
                                HoldCards(holds: cards, card: card, onDecide: onDecide, onScreen: onScreen)
                            }
                            let asked = requests.filter { $0.nodeKey == node.key }
                            if !asked.isEmpty {
                                RequestCards(entries: asked, card: requestCard,
                                             onAnswer: onRequestAnswer, onScreen: onScreen, question: questionBinding, stamp: requestStamp)
                            }
                        }
                        .frame(width: size.width, alignment: .leading)
                    }
                    .frame(maxHeight: TreeLayout.cardsMaxHeight(size: size, canvas: geo.size))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: size.width)
                    .heightReader { cardHeights[node.key] = $0 }
                    .offset(x: origin.x, y: origin.y + size.height) // grid: ok places the cards under their node
                    // After the cards, so it is above them. The card area has no gesture of its own; this drag resizes the node only.
                    let corner = TreeLayout.handleCorner(size: size, cardsHeight: cardHeights[node.key] ?? 0)
                    resizeHandle(node, origin: origin, size: baseSizes[node.key] ?? TreeLayout.nodeSize, drawn: size, canvas: geo.size)
                        .offset(x: origin.x + corner.x - Metric.resizeHandle, y: origin.y + corner.y - Metric.resizeHandle) // grid: ok places the resize handle at the corner
                }
            }
            // The node moves while it is dragged, so the drag is measured in the canvas space, not the node's own.
            .coordinateSpace(name: "tree")
            .overlay(alignment: .topTrailing) { detail.padding(TreeLayout.margin) }
            .overlay(alignment: .bottomLeading) {
                Button {
                    TreeLayout.reset(project: project, in: .standard)
                    layoutVersion += 1
                } label: { KitLabel("Reset", icon: .reset) }
                .buttonStyle(.kit).help("Reset layout")
                .padding(TreeLayout.margin)
            }
        }
    }

    private func resolvedPositions(for tree: WorkerTree, canvas: CGSize, defaultSize: CGSize, widths: [String: CGFloat]) -> [String: CGPoint] {
        var positions = TreeLayout.resolved(keys: tree.nodes.map(\.key), project: project, canvas: canvas, nodeSize: defaultSize,
                                            cardsHeights: liveCardHeights(for: tree), widths: widths, in: .standard)
        if let drag { positions[drag.key] = drag.position }
        return positions
    }

    /// The measured card heights of the nodes that have cards now. An entry stays in `cardHeights` after the cards go away,
    /// because the card view that wrote it leaves the tree, so a stale entry must not push a row down.
    private func liveCardHeights(for tree: WorkerTree) -> [String: CGFloat] {
        cardHeights.filter { entry in tree.nodes.contains { $0.key == entry.key && hasCards($0) } }
    }

    /// A node has cards when it has a hold whose label is its key or an open permission request.
    private func hasCards(_ node: WorkerTreeNode) -> Bool {
        (node.kind == .worker && holds.contains { $0.label == node.key })
            || requests.contains { $0.nodeKey == node.key }
    }

    private func resolvedSizes(for tree: WorkerTree, defaultSize: CGSize) -> [String: CGSize] {
        var sizes = TreeLayout.sizes(keys: tree.nodes.map(\.key), project: project, nodeSize: defaultSize, in: .standard)
        if let resize { sizes[resize.key] = resize.size }
        return sizes
    }

    private func centre(_ origin: CGPoint, _ size: CGSize?) -> CGPoint {
        let size = size ?? TreeLayout.nodeSize
        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    private func bottom(_ origin: CGPoint, _ size: CGSize?) -> CGPoint {
        let size = size ?? TreeLayout.nodeSize
        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height)
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .trailing, spacing: Space.sm) {
            switch result {
            case .none:
                EmptyView()
            case .noDatabase, .noState:
                KitNote(text: "no worker state")
            case .failed:
                EmptyView()
            case .permissionDenied:
                KitNote(text: "grant access: allow this app to read your Documents folder, so it can read worker state")
                HStack(spacing: Space.sm) {
                    Button { NSWorkspace.shared.open(Self.settingsURL) } label: { KitLabel("Open System Settings", icon: .settings) }
                        .buttonStyle(.kit)
                    Button(action: retry) { KitLabel("Retry", icon: .refresh) }
                        .buttonStyle(.kit)
                }
            case .loaded(let state):
                if !state.missing.isEmpty { KitNote(text: "limited state: missing \(state.missing.joined(separator: ", "))") }
            }
        }
        .frame(maxWidth: Metric.treeDetailMaxWidth, alignment: .trailing)
    }

    /// Hidden rows are already absent from the model (D-06).
    private var tree: WorkerTree {
        WorkerTree(orchestratorTitle: orchestratorTitle, result: result, log: log, now: now,
                   holds: holds, cover: blockCover, deadLabels: deadLabels)
    }

    /// `size` is the drawn size, `own` the node's own size. While a prompt draws the node wider, the body drag is inert (D-21):
    /// no move starts and a move that began unwidened saves a position only if the node is not drawn wider on release.
    private func nodeView(_ node: WorkerTreeNode, origin: CGPoint, size: CGSize, own: CGSize, canvas: CGSize) -> some View {
        let lines = nodeInfo[node.key] ?? []
        // The card draws the look and reads its own accessibility label. The tap and drag below are this screen's.
        return KitNodeCard(title: node.title, taskTitle: node.taskTitle, status: node.status, lines: lines,
                           forced: drag?.key == node.key ? .pressed : nil)
        .onTapGesture { onNodeTap(node) }
        .accessibilityAction { onNodeTap(node) }
        // A minimum distance keeps a short press a tap, so opening the terminal still works.
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("tree"))
            .onChanged { value in
                if drag == nil && !TreeLayout.moveMayStart(own: own, drawn: size) { return }
                let base = drag?.base ?? origin
                let moved = CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height)
                let cards = hasCards(node) ? cardHeights[node.key] ?? 0 : 0
                drag = (node.key, base, TreeLayout.clamp(moved, to: canvas, size: size, cardsHeight: cards))
            }
            .onEnded { _ in
                if let drag, let point = TreeLayout.moveSavePosition(inFlight: drag.position, own: own, drawn: size) {
                    TreeLayout.save(point, for: drag.key, project: project, in: .standard)
                }
                drag = nil
                layoutVersion += 1
            })
    }

    /// A press starts the resize at once (minimum distance 0), so a short press on the handle is neither a tap nor a move.
    /// The handle is invisible; the resize cursor on hover is how the user finds it.
    /// `size` is the node's own size, `drawn` the size it is drawn at. While a prompt draws the node wider the handle is inert
    /// (D-21): no resize starts, a drag that began unwidened saves only a size the node is drawn at on release, the cursor
    /// is the normal one and VoiceOver is not offered the action.
    @ViewBuilder private func resizeHandle(_ node: WorkerTreeNode, origin: CGPoint, size: CGSize, drawn: CGSize, canvas: CGSize) -> some View {
        let widened = drawn.width > size.width
        Color.clear
            .frame(width: Metric.resizeHandle, height: Metric.resizeHandle)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tree"))
                .onChanged { value in
                    if resize == nil && !TreeLayout.resizeMayStart(own: size, drawn: drawn) { return }
                    let base = resize?.base ?? size
                    let grown = CGSize(width: base.width + value.translation.width, height: base.height + value.translation.height)
                    let room = CGSize(width: canvas.width - origin.x, height: canvas.height - origin.y)
                    resize = (node.key, base, TreeLayout.clampSize(grown, room: room))
                }
                .onEnded { _ in
                    if let resize, let seen = TreeLayout.resizeSaveSize(inFlight: resize.size, drawn: drawn) {
                        TreeLayout.saveSize(seen, for: resize.key, project: project, in: .standard)
                    }
                    resize = nil
                    layoutVersion += 1
                })
            .accessibilityLabel("Resize \(node.title)")
            .accessibilityHidden(widened)
            .pointerStyle(widened ? nil : .frameResize(position: .bottomTrailing))
    }
}
