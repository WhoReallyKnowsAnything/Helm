import SwiftUI

/// The frame of the workflow area (D-01): a header with the phase picker and a line naming the picked phase and the
/// current tab, the stage tab bar, then one content region. It holds no data and no actions: the caller passes the
/// phases, the picks and the content, so the live shell reuses it unchanged. The editor case (D-02 of phase 6) is an
/// optional view drawn below the tab bar, over the tab body, which stays mounted but hidden so its scroll offset survives.
struct WorkflowShellFrame<Content: View>: View {
    static var stageTabs: [KitStageTab] {
        ["Board", "Context", "Plan", "Execute", "Verify"].map { KitStageTab(id: $0.lowercased(), title: $0) }
    }
    static var projectTabs: [KitStageTab] {
        [KitStageTab(id: "run", title: "Run Record"), KitStageTab(id: "milestone", title: "Milestone")]
    }

    let phases: [KitPhaseOption]
    let phase: String
    /// The id of the selected tab: board, context, plan, execute, verify, run or milestone.
    let tab: String
    var onPickPhase: (String) -> Void = { _ in }
    var onSelectTab: (String) -> Void = { _ in }
    /// The editor of a file link (D-02). When set, it draws below the tab bar and the tab content stays mounted but hidden.
    let editor: AnyView?
    /// The project hold bar (D-03 of phase 6). It draws between the tab bar and the content, outside the content scroll view.
    let holdBar: AnyView?
    let content: Content

    init(phases: [KitPhaseOption], phase: String, tab: String, onPickPhase: @escaping (String) -> Void = { _ in },
         onSelectTab: @escaping (String) -> Void = { _ in }, editor: AnyView? = nil, holdBar: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.editor = editor
        self.holdBar = holdBar
        self.phases = phases
        self.phase = phase
        self.tab = tab
        self.onPickPhase = onPickPhase
        self.onSelectTab = onSelectTab
        self.content = content()
    }

    private var phaseName: String { phases.first { $0.id == phase }?.name ?? "" }
    private var tabTitle: String { (Self.stageTabs + Self.projectTabs).first { $0.id == tab }?.title ?? tab }

    var body: some View {
        VStack(spacing: Space.none) {
            KitHeaderBar {
                KitPhasePicker(phases: phases, picked: phase, onPick: onPickPhase)
                Spacer()
                Text("Phase \(phase)  \(phaseName)  /  \(tabTitle)").kitType(.label).foregroundStyle(Ink.textSecondary).lineLimit(1)
            }
            KitStageTabBar(tabs: Self.stageTabs, trailing: Self.projectTabs, selection: tab, onSelect: onSelectTab)
            if let holdBar { holdBar }
            // One ZStack in both cases, so the tab's ScrollView keeps its place in the tree when the editor appears.
            // The editor sits above it with its own scroll region; the tab is hidden by opacity, never removed.
            ZStack {
                ScrollView { content.frame(maxWidth: .infinity, alignment: .topLeading) }
                    .opacity(editor == nil ? 1 : 0)
                    .allowsHitTesting(editor == nil)
                    .accessibilityHidden(editor != nil)
                if let editor { editor }
            }
        }
    }
}
