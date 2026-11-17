import Testing
@testable import OrchestratorGUI

@Suite struct WorkerPaneTests {
    private func window(_ session: String, _ name: String) -> WindowEntry {
        WindowEntry(session: session, name: name, path: "/p", activity: nil, paneId: "%1")
    }

    private func enabled(_ label: String, status: String = "running", windows: [WindowEntry]? = nil) -> Bool {
        SessionListing.workerTerminalEnabled(label: label, status: status, windows: windows ?? [window("base", label)], session: "base")
    }

    @Test func liveStatusesWithWindowAreEnabled() {
        #expect(enabled("alpha", status: "running"))
        #expect(enabled("alpha", status: "blocked"))
        #expect(enabled("alpha", status: "stalled"))
    }

    /// A "finished" worker is raw status running (last_event done), so the raw status keeps its terminal.
    @Test func finishedWorkerIsRawRunningAndEnabled() {
        #expect(enabled("alpha", status: "running"))
    }

    @Test func missingWindowIsDisabled() {
        #expect(!enabled("alpha", windows: []))
        #expect(!enabled("alpha", windows: [window("base", "dashboard")]))
    }

    @Test func windowOnlyInAnotherSessionIsDisabled() {
        #expect(!enabled("alpha", windows: [window("other", "alpha")]))
    }

    @Test func nonLiveRawStatusIsDisabled() {
        for status in ["done", "merged", "dead", ""] {
            #expect(!enabled("alpha", status: status))
        }
    }

    @Test func labelsOutsideThePatternAreDisabledEvenWithAWindow() {
        for label in ["a b", "x;y", "-x", "", "a$(id)", "a\n"] {
            #expect(!enabled(label))
        }
    }

    @Test func labelsInsideThePatternAreEnabled() {
        for label in ["alpha", "w.1", "_x", "a-b"] {
            #expect(enabled(label))
        }
    }

    // MARK: the tree and a terminal share one area

    /// `main` switches on the screen value, so after every step the area holds exactly the tree or exactly one terminal.
    @Test func theAreaHoldsTheTreeOrOneTerminalAfterEveryStep() {
        func node(_ kind: WorkerTreeNode.Kind, _ key: String) -> WorkerTreeNode {
            WorkerTreeNode(key: key, kind: kind, title: key, taskTitle: nil, status: nil)
        }
        var nav = NavigationState.none.selecting("base")
        #expect(nav.screen == .tree)
        nav = nav.openingTerminal(of: node(.orchestrator, "dashboard"))
        #expect(nav.screen == .terminal(label: "dashboard", waitingCue: false))
        nav = nav.showingTree()
        #expect(nav.screen == .tree)
        nav = nav.openingTerminal(of: node(.worker, "alpha"))
        #expect(nav.screen == .terminal(label: "alpha", waitingCue: false))
        nav = nav.selecting("other")
        #expect(nav.screen == .tree)
    }
}
