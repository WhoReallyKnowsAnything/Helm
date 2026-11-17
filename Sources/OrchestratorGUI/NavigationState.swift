import Foundation

/// Which project is selected and what its area shows: its tree, or one node's terminal in the same space (D-02).
/// A value type with no UI imports. Every transition returns a new value.
struct NavigationState: Equatable {
    enum Screen: Equatable {
        case tree
        /// `label` is the tmux window: `WorkerTree.orchestratorKey` for the orchestrator, else the worker's label.
        /// `waitingCue` is true when a gate-hold banner opened it.
        case terminal(label: String, waitingCue: Bool)
        /// D-17: a root session is its `dashboard` terminal. It has no tree, no Back and no cue.
        case root
        /// The workflow area: the picked phase and the picked tab (D-01). The phase text stays a string ("3", never "3.0").
        /// `tab` is a `WorkflowTabs` id.
        case workflow(phase: String, tab: String)
        /// The editor screen of one file. `path` is the file path as text, `line` the 1-based line to open at,
        /// `origin` the screen the link was on, so Back returns to it.
        indirect case editor(path: String, line: Int?, origin: Screen)
    }

    let project: String?
    let screen: Screen

    static let none = NavigationState(project: nil, screen: .tree)

    /// A sidebar click, a new project or a new root session. Another project drops any open terminal and the cue.
    /// A root session opens on its terminal and never on the tree (D-17).
    func selecting(_ id: String, root: Bool = false) -> NavigationState {
        NavigationState(project: id, screen: root ? .root : .tree)
    }

    /// The sidebar click: the selected row deselects, any other row is selected.
    func clickingSidebarRow(_ id: String, root: Bool = false) -> NavigationState {
        project == id ? .none : selecting(id, root: root)
    }

    func deselected() -> NavigationState { .none }

    /// A tap on a node. Needs a selected project.
    func openingTerminal(of node: WorkerTreeNode) -> NavigationState {
        guard let project, screen != .root else { return self }
        let label = node.kind == .orchestrator ? WorkerTree.orchestratorKey : node.key
        return NavigationState(project: project, screen: .terminal(label: label, waitingCue: false))
    }

    /// Opens the workflow area at a phase and tab. Needs a selected project that is not a root.
    func openingWorkflow(phase: String, tab: String) -> NavigationState {
        guard let project, screen != .root else { return self }
        return NavigationState(project: project, screen: .workflow(phase: phase, tab: tab))
    }

    /// The phase picker. Keeps the tab. Outside the workflow area it returns self.
    func pickingPhase(_ phase: String) -> NavigationState {
        guard case .workflow(_, let tab) = screen else { return self }
        return NavigationState(project: project, screen: .workflow(phase: phase, tab: tab))
    }

    /// A tab click. Keeps the phase. Outside the workflow area it returns self.
    func pickingTab(_ tab: String) -> NavigationState {
        guard case .workflow(let phase, _) = screen else { return self }
        return NavigationState(project: project, screen: .workflow(phase: phase, tab: tab))
    }

    /// A code file link. Needs a selected project that is not a root. The current screen becomes the origin.
    func openingEditor(path: String, line: Int?) -> NavigationState {
        guard let project, screen != .root else { return self }
        return NavigationState(project: project, screen: .editor(path: path, line: line, origin: screen))
    }

    /// Back. The editor returns its origin screen of the same project. Any other screen that can go back acts like `showingTree()`.
    func goingBack() -> NavigationState {
        if case .editor(_, _, let origin) = screen { return NavigationState(project: project, screen: origin) }
        return canGoBack ? showingTree() : self
    }

    /// A gate-hold banner click: selects its project and opens that worker's terminal with the cue.
    /// A banner of the same project leaves an open root or stage screen (workflow) as it is. A root has no worker terminal and no cue.
    func openingFromHoldBanner(project id: String, label: String) -> NavigationState {
        if project == id {
            switch screen {
            case .root, .workflow, .editor: return self
            case .tree, .terminal: break
            }
        }
        return NavigationState(project: id, screen: .terminal(label: label, waitingCue: true))
    }

    /// Back, Dispatch sent, and the start of a merge or teardown. Same project, tree, no cue. A root has no tree.
    func showingTree() -> NavigationState {
        screen == .root ? self : NavigationState(project: project, screen: .tree)
    }

    /// Back applies on a terminal screen and on the workflow screen.
    var canGoBack: Bool {
        switch screen {
        case .terminal, .workflow, .editor: return true
        case .tree, .root: return false
        }
    }

    /// The phase and tab the workflow area shows: on a workflow screen, and on an editor opened from one (the tab stays under it).
    var workflowPick: (phase: String, tab: String)? {
        switch screen {
        case .workflow(let phase, let tab): return (phase, tab)
        case .editor(_, _, .workflow(let phase, let tab)): return (phase, tab)
        default: return nil
        }
    }

    /// The open editor's file path and line, or nil when the screen is not an editor.
    var openEditor: (path: String, line: Int?)? {
        if case .editor(let path, let line, _) = screen { return (path, line) }
        return nil
    }

    var terminalLabel: String? {
        switch screen {
        case .terminal(let label, _): return label
        case .root: return WorkerTree.orchestratorKey
        case .tree, .workflow, .editor: return nil
        }
    }

    /// The waiting and running counts the top band shows for a tree's counts. A root has no tree, so zero and zero.
    func bandCounts(waiting: Int, running: Int) -> (waiting: Int, running: Int) {
        screen == .root ? (0, 0) : (waiting, running)
    }

    /// The bottom Dispatch bar: a project with a folder, on the tree only. A terminal shows its own prompt box.
    func showsDispatchBar(hasFolder: Bool) -> Bool { hasFolder && screen == .tree }

    var showsWaitingCue: Bool {
        if case .terminal(_, let cue) = screen { return cue }
        return false
    }

    /// The open terminal's worker label, or nil on the tree and for the orchestrator.
    var workerLabel: String? {
        terminalLabel.flatMap { $0 == WorkerTree.orchestratorKey ? nil : $0 }
    }
}
