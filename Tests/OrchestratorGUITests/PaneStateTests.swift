import Testing
@testable import OrchestratorGUI

@Suite struct PaneStateTests {
    private let rows = [SessionRow(id: "a", title: "A"), SessionRow(id: "b", title: "B")]

    @Test func selectedPresentAndRunningIsLive() {
        #expect(SessionListing.paneState(selected: "a", rows: rows, processExited: false) == .live)
    }

    @Test func selectedAbsentIsEnded() {
        #expect(SessionListing.paneState(selected: "gone", rows: rows, processExited: false) == .ended)
    }

    @Test func processExitedWithIdPresentIsEnded() {
        #expect(SessionListing.paneState(selected: "a", rows: rows, processExited: true) == .ended)
    }

    @Test func nothingSelectedIsNone() {
        #expect(SessionListing.paneState(selected: nil, rows: rows, processExited: false) == .none)
        #expect(SessionListing.paneState(selected: nil, rows: rows, processExited: true) == .none)
    }
}
