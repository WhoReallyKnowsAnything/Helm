import SwiftUI

/// One part in the gallery. `states` are the states that apply to the part, and `cell` draws it forced into one of them.
/// The gallery and its render test both read this list, so a part cannot be added without its states showing.
struct KitPart: Identifiable {
    let name: String
    let states: [KitState]
    let cell: @MainActor (KitState) -> AnyView

    var id: String { name }

    init<V: View>(_ name: String, states: [KitState] = [.normal], @ViewBuilder cell: @escaping @MainActor (KitState) -> V) {
        self.name = name
        self.states = states
        self.cell = { AnyView(cell($0)) }
    }
}

/// The parts gallery (AC1): the tokens, then every part in every state that applies to it. Dark only.
struct KitGallery: View {
    /// Every part of design/KIT.md. Each plan task adds its parts here.
    @MainActor static let parts: [KitPart] = [
        KitPart("Standard button", states: [.normal, .hover, .pressed, .disabled, .focus]) { state in
            Button {} label: { KitLabel("Dispatch", icon: .send) }.buttonStyle(KitButtonStyle(forced: state))
        },
        KitPart("Primary button", states: [.normal, .hover, .pressed, .disabled, .focus]) { state in
            Button {} label: { KitLabel("Dispatch", icon: .send) }.buttonStyle(KitButtonStyle(kind: .primary, forced: state))
        },
        KitPart("Prompt option button", states: [.normal, .pressed]) { state in
            Button {} label: { Text("2. Yes, allow all edits during this session (shift+tab)") }
                .buttonStyle(KitPromptButtonStyle(forced: state))
                .frame(width: Space.xxxl * 6)
        },
        KitPart("Header bar", states: [.normal, .inactive]) { state in
            KitHeaderBar(forced: state) {
                Text("project-one")
                Spacer()
                Button {} label: { KitLabel("Close", icon: .close) }.buttonStyle(.kit)
            }
            .frame(width: Space.xxxl * 12)
        },
        KitPart("Prompt bar", states: [.normal, .inactive]) { state in
            KitPromptBar(text: .constant(""), forced: state, action: {}).frame(width: Space.xxxl * 12)
        },
        KitPart("Prompt bar, with text") { _ in
            KitPromptBar(text: .constant("add the export"), action: {}).frame(width: Space.xxxl * 12)
        },
        KitPart("Footer line") { _ in
            KitFooterLine {
                Text("5h  8% used  resets 21:40")
                Text("7d  45% used  resets Fri 09:00")
            }
            .frame(width: Space.xxxl * 12)
        },
        KitPart("Note") { _ in KitNote(text: "usage: no data") },
        KitPart("Notice") { _ in
            KitNotice(text: "Session ended").frame(width: Space.xxxl * 12, height: Space.xxxl * 2)
        },
        KitPart("Notice, with action") { _ in
            KitNotice(text: "Session ended") { Button("Reconnect") {}.buttonStyle(.kit) }
                .frame(width: Space.xxxl * 12, height: Space.xxxl * 3)
        },
        KitPart("Sidebar row", states: [.normal, .hover, .pressed, .selected, .inactive, .disabled, .focus]) { state in
            KitSidebarRow(title: "project-one", id: "orch-7f3a", forced: state) {}
                .padding(Space.sm).frame(width: Space.xxxl * 7).background(Ink.sidebar)
        },
        KitPart("Sidebar row, needs attention") { _ in
            KitSidebarRow(title: "project-one", id: "orch-7f3a", needsAttention: true) {}
                .padding(Space.sm).frame(width: Space.xxxl * 7).background(Ink.sidebar)
        },
        KitPart("Dormant sidebar row") { _ in
            KitDormantRow(title: "project-one", id: "orch-7f3a")
                .padding(Space.sm).frame(width: Space.xxxl * 7).background(Ink.sidebar)
        },
        KitPart("Dormant sidebar row, restoring") { _ in
            KitDormantRow(title: "project-one", id: "orch-7f3a", running: true)
                .padding(Space.sm).frame(width: Space.xxxl * 7).background(Ink.sidebar)
        },
        KitPart("Splitter", states: [.normal, .hover]) { state in
            KitSplitter(size: .constant(260), range: 200...600, forced: state)
                .frame(height: Space.xxxl)
        },
        KitPart("Node card", states: [.normal, .hover, .pressed, .focus]) { state in
            nodeCard(nil, forced: state)
        },
        KitPart("Node card, every status") { _ in
            HStack(spacing: Space.lg) {
                ForEach([WorkerStatus.running, .waiting, .stalled, .finished], id: \.self) { nodeCard($0) }
            }
        },
        KitPart("Node card, no status") { _ in nodeCard(nil) },
        KitPart("Dot grid") { _ in
            KitDotGrid().background(Ink.background).frame(width: Space.xxxl * 12, height: Space.xxxl * 4)
        },
        KitPart("Hold card") { _ in holdCard(stateLine: "waiting for your decision", outcome: nil, buttonsOff: false, buttons: true) },
        KitPart("Hold card, deciding") { _ in holdCard(stateLine: "waiting for your decision", outcome: nil, buttonsOff: true, buttons: true) },
        KitPart("Hold card, decided") { _ in holdCard(stateLine: nil, outcome: "Approved", buttonsOff: false, buttons: false) },
        KitPart("Sheet frame") { _ in sheetFrames(failure: nil, progress: nil) },
        KitPart("Sheet frame, failure line") { _ in sheetFrames(failure: "The branch is not up to date with main.", progress: nil) },
        KitPart("Sheet frame, progress row") { _ in sheetFrames(failure: nil, progress: "Merging. This can take a few minutes.") },
        KitPart("Sheet frame, close only") { _ in
            KitSheetFrame(title: "Dispatch", width: SheetWidth.medium, cancelTitle: "Close", cancel: {}) {
                Text("Add the export").kitType(.label).foregroundStyle(Ink.text)
            }
        },
        KitPart("Alert dot") { _ in KitAlertDot() },
        KitPart("Status dot and status text") { _ in
            HStack(spacing: Space.xl) {
                ForEach([WorkerStatus.running, .waiting, .stalled, .finished], id: \.self) { status in
                    HStack(spacing: Space.xs) { KitStatusDot(status: status); KitStatusText(status: status) }
                }
            }
        },
        KitPart("Stage tab bar", states: [.normal, .hover, .pressed, .selected, .disabled, .focus]) { state in
            KitStageTabBar(tabs: stageTabs, trailing: projectTabs, selection: "board", forcedTab: "plan",
                           forced: state, onSelect: { _ in })
        },
        KitPart("Phase picker", states: [.normal, .hover, .pressed, .disabled, .focus]) { state in
            KitPhasePicker(phases: [KitPhaseOption(id: "5", name: "Workflow area redesign"), KitPhaseOption(id: "6", name: "Wire phases 1-4")],
                           picked: "5", forced: state, onPick: { _ in })
        },
        KitPart("Stage action row", states: [.normal, .hover, .pressed, .disabled, .focus]) { state in
            KitStageActionRow(primaryTitle: "Approve", primaryReason: state == .disabled ? "plan is still running" : nil,
                              menuTitle: "Suggested", forced: state, onPrimary: {},
                              secondary: { Button("Change Notes") {}.buttonStyle(.kit) },
                              menu: { Button("cad-coverage 5") {} })
        },
        KitPart("Board row") { _ in
            KitBoardRow(number: "3", name: "Wire holds", stage: "planned") {}.frame(width: Space.xxxl * 16)
        },
        KitPart("Board row, dead worker") { _ in
            KitBoardRow(number: "2", name: "Workflow screen redesign", stage: "verify", status: (.dead, "dead worker")) {
                Button("Clear cad-verify-p2") {}.buttonStyle(.kit)
            }
            .frame(width: Space.xxxl * 16)
        },
        KitPart("Board row, hold mark and actions") { _ in
            KitBoardRow(number: "3", name: "Wire holds", stage: "planned", cursor: true, status: (.running, "executing"),
                        holdText: "git commit waiting") {
                Button("Open Execute") {}.buttonStyle(.kit)
                Button("decision-review") {}.buttonStyle(.kit)
            }
            .frame(width: Space.xxxl * 16)
        },
    ]

    private static let stageTabs = ["Board", "Context", "Plan", "Execute", "Verify"].map { KitStageTab(id: $0.lowercased(), title: $0) }
    private static let projectTabs = [KitStageTab(id: "run", title: "Run Record"), KitStageTab(id: "milestone", title: "Milestone")]

    private static let colours: [(String, Color)] = [
        ("background", Ink.background), ("sidebar", Ink.sidebar), ("header", Ink.header), ("panel", Ink.panel),
        ("selectedRow", Ink.selectedRow), ("dotGrid", Ink.dotGrid),
        ("terminal", Ink.terminal), ("border", Ink.border), ("borderStrong", Ink.borderStrong), ("text", Ink.text),
        ("textSecondary", Ink.textSecondary), ("muted", Ink.muted), ("waiting", Ink.waiting), ("running", Ink.running),
        ("merged", Ink.merged), ("stalled", Ink.stalled), ("accent.fill", Ink.accent.fill), ("accent.text", Ink.accent.text),
        ("accent.onAccent", Ink.accent.onAccent),
    ]

    private static let spacing: [(String, CGFloat)] = [
        ("xs", Space.xs), ("sm", Space.sm), ("md", Space.md), ("lg", Space.lg), ("xl", Space.xl), ("xxl", Space.xxl), ("xxxl", Space.xxxl),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            section("Colours") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.md), count: 4), alignment: .leading, spacing: Space.md) {
                    ForEach(Self.colours, id: \.0) { name, colour in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            RoundedRectangle(cornerRadius: Metric.corner).fill(colour)
                                .frame(height: Space.xxl)
                                .overlay(RoundedRectangle(cornerRadius: Metric.corner).stroke(Ink.borderStrong, lineWidth: Metric.hairline))
                            Text(name).kitType(.meta).foregroundStyle(Ink.textSecondary)
                        }
                    }
                }
            }
            section("Type") {
                ForEach(KitType.allCases, id: \.self) { role in
                    HStack(spacing: Space.lg) {
                        Text("\(role)".capitalized).kitType(.meta).foregroundStyle(Ink.muted)
                            .frame(width: Space.xxxl * 3, alignment: .leading)
                        Text("worker-3  orch-7f3a 0123").kitType(role).foregroundStyle(Ink.text)
                    }
                }
            }
            section("Spacing") {
                ForEach(Self.spacing, id: \.0) { name, value in
                    HStack(spacing: Space.md) {
                        Text(name).kitType(.meta).foregroundStyle(Ink.muted)
                            .frame(width: Space.xxxl * 2, alignment: .leading)
                        Rectangle().fill(Ink.accent.fill).frame(width: value * 4, height: Space.sm)
                    }
                }
            }
            section("Motion") {
                HStack(spacing: Space.lg) {
                    ForEach(Motion.allCases, id: \.self) { motion in
                        Text(String(describing: motion)).kitType(.label).foregroundStyle(Ink.textSecondary)
                    }
                }
            }
            section("Icons") {
                HStack(spacing: Space.lg) {
                    ForEach(KitIcon.allCases, id: \.self) { icon in
                        VStack(spacing: Space.xs) {
                            KitImage(icon).foregroundStyle(Ink.text)
                            Text(String(describing: icon)).kitType(.meta).foregroundStyle(Ink.muted)
                        }
                    }
                }
            }
            ForEach(Self.parts) { part in
                section(part.name) {
                    HStack(alignment: .top, spacing: Space.xl) {
                        ForEach(part.states, id: \.self) { state in
                            VStack(alignment: .leading, spacing: Space.sm) {
                                part.cell(state)
                                Text(state.rawValue).kitType(.meta).foregroundStyle(Ink.muted)
                            }
                        }
                    }
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.background)
    }

    /// A node card at the default node size of the tree.
    @MainActor private static func nodeCard(_ status: WorkerStatus?, forced: KitState? = nil) -> some View {
        KitNodeCard(title: "worker-3", taskTitle: "Add the export", status: status, lines: ["opus-4 · high", "~/work/project-one"], forced: forced)
            .frame(width: TreeLayout.nodeSize.width, height: TreeLayout.nodeSize.height)
    }

    /// The sheet frame at each of the three sheet widths.
    @MainActor private static func sheetFrames(failure: String?, progress: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach([SheetWidth.small, SheetWidth.medium, SheetWidth.large], id: \.self) { width in
                KitSheetFrame(title: "Dispatch a Task", width: width, failure: failure, progress: progress,
                              primaryTitle: "Dispatch", cancel: {}, primary: {}) {
                    TextField("Task", text: .constant("Add the export"))
                }
            }
        }
    }

    /// A hold card as wide as the narrowest default node, with the Approve and Deny pair side by side.
    @MainActor private static func holdCard(stateLine: String?, outcome: String?, buttonsOff: Bool, buttons: Bool) -> some View {
        KitHoldCard(stateLine: stateLine, outcome: outcome) {
            Text("git push origin main").kitType(.label).foregroundStyle(Ink.text)
        } decision: {
            if buttons {
                KitButtonPair {
                    Button("Approve") {}.buttonStyle(.kit)
                    Button("Deny") {}.buttonStyle(.kit)
                }
                .disabled(buttonsOff)
            }
        }
        .frame(width: TreeLayout.nodeSize.width)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(title).kitType(.section).foregroundStyle(Ink.muted)
            content()
        }
    }
}
