import Foundation
import Testing
@testable import Helm

@Suite struct NavigationStateTests {
    private func node(_ kind: WorkerTreeNode.Kind, _ key: String) -> WorkerTreeNode {
        WorkerTreeNode(key: key, kind: kind, title: key, taskTitle: nil, status: nil)
    }

    private let orchestrator = WorkerTreeNode(key: "dashboard", kind: .orchestrator, title: "base", taskTitle: nil, status: nil)

    // MARK: the four paths of AC2

    @Test func selectingAProjectShowsItsTree() {
        let nav = NavigationState.none.selecting("base")
        #expect(nav.project == "base")
        #expect(nav.screen == .tree)
    }

    @Test func tappingANodeOpensThatNodesTerminal() {
        let base = NavigationState.none.selecting("base")
        #expect(base.openingTerminal(of: orchestrator).screen == .terminal(label: "dashboard", waitingCue: false))
        #expect(base.openingTerminal(of: node(.worker, "alpha")).screen == .terminal(label: "alpha", waitingCue: false))
    }

    @Test func backReturnsToTheTreeOfTheSameProject() {
        let nav = NavigationState.none.selecting("base").openingTerminal(of: node(.worker, "alpha")).showingTree()
        #expect(nav.project == "base")
        #expect(nav.screen == .tree)
    }

    @Test func aHoldBannerOpensTheWorkerTerminalWithTheCue() {
        let nav = NavigationState.none.openingFromHoldBanner(project: "base", label: "alpha")
        #expect(nav.project == "base")
        #expect(nav.screen == .terminal(label: "alpha", waitingCue: true))
        #expect(nav.showsWaitingCue)
        #expect(nav.workerLabel == "alpha")
    }

    // MARK: the other transitions

    @Test func clickingTheSelectedRowDeselectsAndAnotherRowSelects() {
        let nav = NavigationState.none.selecting("base")
        #expect(nav.clickingSidebarRow("base") == .none)
        #expect(nav.clickingSidebarRow("other") == NavigationState.none.selecting("other"))
        #expect(NavigationState.none.clickingSidebarRow("base") == nav)
    }

    @Test func dispatchSentAndMergeOrTeardownStartLandOnTheTree() {
        let open = NavigationState.none.selecting("base").openingTerminal(of: node(.worker, "alpha"))
        #expect(open.showingTree() == NavigationState.none.selecting("base"))
        #expect(NavigationState.none.selecting("base").showingTree().screen == .tree)
    }

    @Test func changingTheProjectDropsTheOpenTerminalAndTheCue() {
        let open = NavigationState.none.openingFromHoldBanner(project: "base", label: "alpha")
        let moved = open.selecting("other")
        #expect(moved.project == "other")
        #expect(moved.screen == .tree)
        #expect(!moved.showsWaitingCue)
    }

    @Test func backClearsTheCue() {
        let nav = NavigationState.none.openingFromHoldBanner(project: "base", label: "alpha").showingTree()
        #expect(!nav.showsWaitingCue)
        #expect(nav.terminalLabel == nil)
    }

    @Test func backAppliesOnATerminalScreenOnly() {
        #expect(!NavigationState.none.canGoBack)
        #expect(!NavigationState.none.selecting("base").canGoBack)
        #expect(NavigationState.none.selecting("base").openingTerminal(of: orchestrator).canGoBack)
        #expect(NavigationState.none.openingFromHoldBanner(project: "base", label: "alpha").canGoBack)
    }

    @Test func aNodeTapWithNoProjectDoesNothing() {
        #expect(NavigationState.none.openingTerminal(of: orchestrator) == .none)
    }

    @Test func theOrchestratorTerminalHasNoWorkerLabel() {
        let nav = NavigationState.none.selecting("base").openingTerminal(of: orchestrator)
        #expect(nav.terminalLabel == "dashboard")
        #expect(nav.workerLabel == nil)
    }

    // MARK: D-17, a root session is a terminal

    private let root = NavigationState.none.selecting("home", root: true)

    @Test func aRootSelectionLandsOnTheRootTerminalWithNoBackAndNoCue() {
        #expect(root.project == "home")
        #expect(root.screen == .root)
        #expect(root.terminalLabel == "dashboard")
        #expect(root.workerLabel == nil)
        #expect(!root.showsWaitingCue)
        #expect(!root.canGoBack)
    }

    @Test func aRootHasNoTreeAndNoNodeToOpen() {
        #expect(root.showingTree() == root)
        #expect(root.openingTerminal(of: orchestrator) == root)
        #expect(root.openingTerminal(of: node(.worker, "alpha")) == root)
    }

    @Test func aHoldBannerFocusOnTheOpenRootKeepsTheRootScreen() {
        let nav = root.openingFromHoldBanner(project: "home", label: "dashboard")
        #expect(nav == root)
        #expect(nav.screen == .root && !nav.canGoBack && !nav.showsWaitingCue)
    }

    @Test func aHoldBannerOfAnotherProjectStillOpensItsTerminal() {
        let nav = root.openingFromHoldBanner(project: "base", label: "alpha")
        #expect(nav.screen == .terminal(label: "alpha", waitingCue: true))
    }

    @Test func aHoldBannerOfTheSameProjectKeepsAnOpenStageScreen() {
        let base = NavigationState.none.selecting("base")
        let stages = [base.openingWorkflow(phase: "2", tab: "context"), base.openingWorkflow(phase: "2", tab: "plan"),
                      base.openingWorkflow(phase: "2", tab: "verify"), base.openingWorkflow(phase: "2", tab: "execute"),
                      base.openingWorkflow(phase: "2", tab: "run"), base.openingWorkflow(phase: "2", tab: "milestone")]
        for stage in stages {
            #expect(stage.openingFromHoldBanner(project: "base", label: "cad-execute-p2") == stage)
        }
    }

    @Test func aHoldBannerOfAnotherProjectLeavesAStageScreen() {
        let nav = NavigationState.none.selecting("base").openingWorkflow(phase: "2", tab: "execute")
            .openingFromHoldBanner(project: "other", label: "alpha")
        #expect(nav.project == "other")
        #expect(nav.screen == .terminal(label: "alpha", waitingCue: true))
    }

    @Test func clickingTheRootRowTwiceSelectsThenDeselects() {
        let selected = NavigationState.none.clickingSidebarRow("home", root: true)
        #expect(selected.screen == .root)
        #expect(selected.clickingSidebarRow("home", root: true) == .none)
    }

    @Test func rootToProjectLandsOnTheTreeAndProjectToRootOnTheRootScreen() {
        let toProject = root.selecting("base")
        #expect(toProject.screen == .tree)
        #expect(!toProject.canGoBack)
        let toRoot = NavigationState.none.selecting("base").selecting("home", root: true)
        #expect(toRoot.screen == .root)
    }

    @Test func aProjectKeepsItsTreeItsNodeTerminalAndItsBack() {
        let base = NavigationState.none.selecting("base")
        #expect(base.screen == .tree)
        #expect(base.openingTerminal(of: node(.worker, "alpha")).screen == .terminal(label: "alpha", waitingCue: false))
        #expect(base.openingTerminal(of: orchestrator).canGoBack)
    }

    @Test func theBandShowsNoCountsForARootAndTheGivenCountsForAProject() {
        #expect(root.bandCounts(waiting: 2, running: 3) == (0, 0))
        #expect(NavigationState.none.selecting("base").bandCounts(waiting: 2, running: 3) == (2, 3))
    }

    @Test func theDispatchBarNeverShowsForARoot() {
        #expect(!root.showsDispatchBar(hasFolder: true))
        #expect(NavigationState.none.selecting("base").showsDispatchBar(hasFolder: true))
        #expect(!NavigationState.none.selecting("base").showsDispatchBar(hasFolder: false))
        #expect(!NavigationState.none.selecting("base").openingTerminal(of: node(.worker, "alpha")).showsDispatchBar(hasFolder: true))
    }
}

@Suite struct NavigationWorkflowScreenTests {
    private let base = NavigationState.none.selecting("base")

    @Test func openingKeepsThePhaseTextExactlyAndBackReturnsToTheTree() {
        let nav = base.openingWorkflow(phase: "1.1", tab: "plan")
        #expect(nav.screen == .workflow(phase: "1.1", tab: "plan"))
        #expect(nav.canGoBack)
        #expect(nav.terminalLabel == nil)
        #expect(!nav.showsDispatchBar(hasFolder: true))
        #expect(nav.goingBack().screen == .tree)
        #expect(nav.showingTree().screen == .tree)
    }

    @Test func pickingAPhaseKeepsTheTabAndPickingATabKeepsThePhase() {
        let nav = base.openingWorkflow(phase: "3", tab: "context")
        #expect(nav.pickingPhase("1.1").screen == .workflow(phase: "1.1", tab: "context"))
        #expect(nav.pickingTab("verify").screen == .workflow(phase: "3", tab: "verify"))
    }

    @Test func pickingOutsideTheWorkflowAreaChangesNothing() {
        #expect(base.pickingPhase("2") == base)
        #expect(base.pickingTab("plan") == base)
    }

    @Test func pickingRunOrMilestoneKeepsThePhase() {
        let nav = base.openingWorkflow(phase: "3", tab: "board")
        #expect(nav.pickingTab("run").screen == .workflow(phase: "3", tab: "run"))
        #expect(nav.pickingTab("milestone").screen == .workflow(phase: "3", tab: "milestone"))
    }

    @Test func anotherProjectDropsTheScreen() {
        #expect(base.openingWorkflow(phase: "4", tab: "board").selecting("other").screen == .tree)
    }

    @Test func aRootAndNoProjectCannotOpenIt() {
        let root = NavigationState.none.selecting("r", root: true)
        #expect(root.openingWorkflow(phase: "1", tab: "board") == root)
        #expect(NavigationState.none.openingWorkflow(phase: "1", tab: "board") == .none)
    }
}

@Suite struct NavigationEditorScreenTests {
    private let base = NavigationState.none.selecting("base")

    @Test func backReturnsTheScreenTheLinkWasOn() {
        for origin in [NavigationState.Screen.workflow(phase: "4", tab: "context"), .workflow(phase: "4", tab: "plan"),
                       .workflow(phase: "4", tab: "verify")] {
            let from = NavigationState(project: "base", screen: origin)
            let nav = from.openingEditor(path: "/p/a.swift", line: 12)
            #expect(nav.screen == .editor(path: "/p/a.swift", line: 12, origin: origin))
            #expect(nav.canGoBack)
            #expect(nav.terminalLabel == nil)
            #expect(!nav.showsDispatchBar(hasFolder: true))
            #expect(nav.goingBack() == from)
        }
    }

    @Test func noProjectAndARootAreReturnedUnchanged() {
        #expect(NavigationState.none.openingEditor(path: "/p/a.swift", line: nil) == .none)
        let root = NavigationState.none.selecting("r", root: true)
        #expect(root.openingEditor(path: "/p/a.swift", line: nil) == root)
    }

    @Test func backFromOtherScreensStillReturnsTheTree() {
        let term = base.openingTerminal(of: WorkerTreeNode(key: "dashboard", kind: .orchestrator, title: "base", taskTitle: nil, status: nil))
        #expect(term.goingBack().screen == .tree)
        #expect(base.openingWorkflow(phase: "1", tab: "verify").goingBack().screen == .tree)
        #expect(base.goingBack() == base)
    }

    @Test func showingTreeStillDropsToTheTree() {
        #expect(base.openingEditor(path: "/p/a.swift", line: nil).showingTree().screen == .tree)
    }

    @Test func workflowPickSurvivesAnEditorOpenedFromAWorkflowTab() {
        let from = base.openingWorkflow(phase: "3", tab: "run")
        let nav = from.openingEditor(path: "/p/a.swift", line: 7)
        #expect(from.workflowPick?.phase == "3" && from.workflowPick?.tab == "run")
        #expect(nav.workflowPick?.phase == "3" && nav.workflowPick?.tab == "run")
        #expect(nav.openEditor?.path == "/p/a.swift" && nav.openEditor?.line == 7)
        #expect(nav.goingBack() == from)
        #expect(from.openEditor == nil)
    }

    @Test func workflowPickIsNilForAnEditorOpenedFromTheTree() {
        let nav = base.openingEditor(path: "/p/a.swift", line: nil)
        #expect(nav.workflowPick == nil)
        #expect(nav.openEditor?.path == "/p/a.swift")
    }

    @Test func rootTerminalAndTreeHaveNoWorkflowPickAndNoEditor() {
        let root = NavigationState.none.selecting("r", root: true)
        let term = base.openingTerminal(of: WorkerTreeNode(key: "dashboard", kind: .orchestrator, title: "base", taskTitle: nil, status: nil))
        for nav in [root, term, base] {
            #expect(nav.workflowPick == nil)
            #expect(nav.openEditor == nil)
        }
    }
}

@Suite struct NavigationShellTests {
    private let base = NavigationState.none.selecting("base")
    private let home = NSHomeDirectory()

    private func worker(_ key: String) -> WorkerTreeNode {
        WorkerTreeNode(key: key, kind: .worker, title: key, taskTitle: nil, status: nil)
    }

    @Test func projectShellBackReturnsTheTree() {
        let nav = base.openingShell(folder: "/p")
        #expect(nav.screen == .shell(folder: "/p", origin: .tree))
        #expect(nav.project == "base")
        #expect(nav.goingBack() == base)
    }

    @Test func homeShellFromNoProjectBacksToNone() {
        let nav = NavigationState.none.openingHomeShell()
        #expect(nav.project == nil)
        #expect(nav.screen == .shell(folder: home, origin: .tree))
        #expect(nav.goingBack() == NavigationState.none)
    }

    @Test func homeShellFromAWorkerTerminalBacksToThatTerminal() {
        let term = base.openingTerminal(of: worker("alpha"))
        #expect(term.openingHomeShell().goingBack() == term)
    }

    @Test func oneShellAtATimeKeepsTheFirstOrigin() {
        let project = base.openingShell(folder: "/p")
        #expect(project.openingHomeShell().goingBack() == base)
        #expect(project.openingShell(folder: "/p").goingBack() == base)
        let homeNav = base.openingHomeShell()
        #expect(homeNav.openingHomeShell() == homeNav)
    }

    @Test func holdBannerLeavesTheShell() {
        let nav = base.openingShell(folder: "/p").openingFromHoldBanner(project: "base", label: "alpha")
        #expect(nav.screen == .terminal(label: "alpha", waitingCue: true))
    }

    @Test func shellHasNoTerminalCues() {
        let nav = base.openingShell(folder: "/p")
        #expect(nav.canGoBack)
        #expect(nav.terminalLabel == nil)
        #expect(nav.workerLabel == nil)
        #expect(!nav.showsWaitingCue)
    }

    @Test func switchingProjectOrClosingLeavesTheShell() {
        let nav = base.openingShell(folder: "/p")
        #expect(nav.selecting("other").screen == .tree)
        #expect(nav.clickingSidebarRow("other").screen == .tree)
        #expect(nav.clickingSidebarRow("base") == NavigationState.none)
        #expect(nav.deselected() == NavigationState.none)
    }

    @Test func projectShellDoesNotOpenFromRoot() {
        let root = NavigationState.none.selecting("r", root: true)
        #expect(root.openingShell(folder: "/p") == root)
    }
}
