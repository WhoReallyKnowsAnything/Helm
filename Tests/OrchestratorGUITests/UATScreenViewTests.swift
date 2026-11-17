import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct UATScreenViewTests {
    private let literal = """
        ---
        status: testing
        phase: 3
        fields_version: 1
        ---

        ## Items

        ### 1. First
        expected: See Sources/a.swift
        status: pass
        source: verifier
        reported: ok

        ### 2. Second
        expected: e2
        status: pending

        ### 3. Third
        expected: e3
        status: skipped
        reason: no device
        """

    private func status(_ result: String = "partial") -> UATStatus.Outcome {
        .loaded(UATStatus(status: "testing", counts: .init(pass: 1, pending: 1, skipped: 1), result: result, firstPending: nil, ci: nil))
    }

    @Test func notStartedShowsTheWordAndNoRows() {
        let t = UATScreenText.make(phase: "3", data: UATScreenData(), overlay: nil)
        #expect(t.message == "not started" && t.rows.isEmpty && t.countsLine == nil)
    }

    @Test func loadedShowsRowsAndTheStatusCountsLine() {
        let data = UATScreenData(source: .worktree, status: status(), file: UATFile.parse(literal), path: "/x")
        let t = UATScreenText.make(phase: "3", data: data, overlay: nil)
        #expect(t.rows.count == 3)
        #expect(t.countsLine == "pass 1, fail 0, pending 1, skipped 1, blocked 0 - partial")
        #expect(t.copyLine == "Showing the worktree copy (not merged yet)")
        #expect(t.rows[0].source == "verifier" && t.rows[1].source == nil)
        #expect(t.rows[2].note == "no device" && t.rows[0].note == "ok")
    }

    @Test func projectCopyIsNamed() {
        let data = UATScreenData(source: .project, status: status("complete"), file: UATFile.parse(literal), path: "/x")
        #expect(UATScreenText.make(phase: "3", data: data, overlay: nil).copyLine == "Showing the project copy")
    }

    @Test func unsupportedVersionShowsMessageAndFileLinkAndNoRows() {
        let data = UATScreenData(source: .project, status: status(),
                                 file: UATFile.parse(literal.replacingOccurrences(of: "fields_version: 1", with: "fields_version: 2")), path: "/x")
        let t = UATScreenText.make(phase: "3", data: data, overlay: nil)
        #expect(t.rows.isEmpty && t.message?.contains("fields_version 2") == true)
        #expect(t.rawFileLink == ".planning/phases/3/UAT.md")
    }

    @Test func unreadableStatusShowsItsReasonAndNeverCounts() {
        let data = UATScreenData(source: .project, status: .unreadable("timed out"), file: UATFile.parse(literal), path: "/x")
        let t = UATScreenText.make(phase: "3", data: data, overlay: nil)
        #expect(t.message == "timed out" && t.countsLine == nil)
    }

    private let three = """
        ---
        status: testing
        phase: 3
        fields_version: 1
        ---

        ### 1. A
        expected: e1
        status: pass

        ### 2. B
        expected: e2
        status: pending

        ### 3. C
        expected: e3
        status: pending
        """

    private func overlay(_ state: WorkflowOverlay.State?) -> WorkflowOverlay? {
        state.map { WorkflowOverlay(stage: .verify, state: $0, label: "cad-verify-p3") }
    }

    private func threeData() -> UATScreenData {
        let s = UATStatus(status: "testing", counts: .init(pass: 1, pending: 2), result: "partial",
                          firstPending: .init(k: 2, name: "B", expected: "e2"), ci: nil)
        return UATScreenData(source: .project, status: .loaded(s), file: UATFile.parse(three), path: "/x")
    }

    @Test func onlyTheFirstPendingRowHasControlsAndNotStartedHasNone() {
        let t = UATScreenText.make(phase: "3", data: threeData(), overlay: overlay(.running), live: true, inbox: "/i")
        #expect(t.rows.map(\.isCurrent) == [false, true, false] && t.controlsOff == nil)
        #expect(UATScreenText.make(phase: "3", data: UATScreenData(), overlay: nil).rows.isEmpty)
    }

    @Test func controlsAreOffWithAReasonUnlessRunningAndLive() {
        func off(_ s: WorkflowOverlay.State?, live: Bool = true) -> String? {
            UATScreenText.make(phase: "3", data: threeData(), overlay: overlay(s), live: live, inbox: "/i").controlsOff
        }
        #expect(off(.dead, live: false) == "worker ended")
        #expect(off(.waitingForMerge) == "waiting for merge")
        #expect(off(.running, live: false) == "starting")
        #expect(off(nil) == "worker not running")
    }

    @Test func sendNeedsNonEmptyCleanedText() {
        #expect(!UATResult.canSend("") && !UATResult.canSend("  \n ") && UATResult.canSend("broken"))
    }

    @Test func theReadbackLineShowsUnderTheSentRow() {
        let ok = UATScreenText.make(phase: "3", data: threeData(), overlay: nil, readback: (1, .recorded(status: "pass", note: nil)))
        #expect(ok.rows[0].readback == "recorded as pass" && ok.rows[1].readback == nil)
        let bad = UATScreenText.make(phase: "3", data: threeData(), overlay: nil, readback: (2, .mismatch("sent fail, recorded pass")))
        #expect(bad.rows[1].readback == "mismatch: sent fail, recorded pass")
    }

    @Test func verifyCardStateFollowsTheOverlay() {
        #expect(UATScreenText.cardState(phase: "3", overlay: overlay(.running), live: true) == .answerable)
        let dead = UATScreenText.cardState(phase: "3", overlay: overlay(.dead), live: false)
        #expect(dead == .workerEnded && ContextCardState.offersClear(dead))
        #expect(UATScreenText.cardState(phase: "3", overlay: nil, live: true) == .noCard)
        #expect(ContextCardState.state(label: "cad-execute-p3", overlay: .running, live: true) == .answerable)
    }

    @Test func aPathOnlyInTheWorktreeIsALinkNamingTheWorktreeCopy() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "uat-view-" + UUID().uuidString.prefix(8).lowercased())
        let project = root.appendingPathComponent("p"), wt = root.appendingPathComponent("w")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wt.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: wt.appendingPathComponent("Sources/a.swift"), atomically: true, encoding: .utf8)
        let url = FileLinkView.linkURL("Sources/a.swift", project: project, worktree: wt)
        #expect(url != nil)
        guard case .success(let resolved) = FilePathResolver.resolve("Sources/a.swift", project: project, worktree: wt) else {
            Issue.record("not resolved"); return
        }
        #expect(resolved.root == .worktree)
        #expect(FileLinkView.linkURL("Sources/a.swift", project: project, worktree: nil) == nil)
    }
}
