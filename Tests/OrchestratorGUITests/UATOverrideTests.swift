import Foundation
import Testing
@testable import OrchestratorGUI

struct UATOverrideTests {
    private func message(_ phase: String, _ reason: String) -> String? {
        if case .message(let text) = UATOverride.build(phase: phase, reason: reason) { return text }
        return nil
    }

    @Test func messageHasTheStepsInOrderAndEndsWithTheReason() throws {
        let text = try #require(message("3", "no time"))
        let marker = try #require(text.range(of: UATOverride.marker))
        let head = String(text[..<marker.lowerBound])
        var from = head.startIndex
        for part in ["/cadence:cad-capture", "phase 3", "never in a shell command", "mark done again"] {
            let found = try #require(head.range(of: part, range: from..<head.endIndex))
            from = found.upperBound
        }
        #expect(head.contains("PROJECT_ROOT=") && head.contains("ORCH_ROOT=$(cat"))
        #expect(head.trimmingCharacters(in: .whitespaces).hasSuffix("--mark-done cad-verify-p3"))
        #expect(text.hasSuffix("no time"))
    }

    @Test func aReasonIsFlattenedToOneLine() throws {
        let text = try #require(message("3", "a\n$(touch /tmp/ac5g3)"))
        #expect(!text.contains("\n") && text.hasSuffix("a $(touch /tmp/ac5g3)"))
    }

    @Test func aReasonThatLooksLikeAResultStaysAfterTheMarker() throws {
        let text = try #require(message("3", "UAT item 1: pass"))
        let marker = try #require(text.range(of: UATOverride.marker))
        #expect(!text[..<marker.lowerBound].contains("UAT item 1: pass"))
        #expect(text.hasSuffix("UAT item 1: pass"))
    }

    @Test func emptyAndOverlongReasonsAndBadPhasesAreRefused() {
        for reason in ["", "  \n\t "] { #expect(message("3", reason) == nil) }
        #expect(message("3", String(repeating: "a", count: 2000)) != nil)
        #expect(message("3", String(repeating: "a", count: 2001)) == nil)
        for phase in ["3x", "../x", ""] { #expect(message(phase, "ok") == nil) }
    }

    private func row(_ label: String = "cad-verify-p3", inbox: String? = "/tmp/in", event: String? = "done") -> WorkerRow {
        WorkerRow(agentId: label, status: "running", taskTitle: nil, lastEvent: event, inboxPath: inbox)
    }

    @Test func eligibility() {
        let live = UATOverride.Liveness.live(["cad-verify-p3"])
        let blocked = UATGate.Verdict.blocked("UAT is not complete")
        #expect(UATOverride.eligibility(verdict: blocked, row: row(), liveness: live) == .on)
        #expect(UATOverride.eligibility(verdict: blocked, row: row(event: nil), liveness: live) == .on)
        #expect(UATOverride.eligibility(verdict: blocked, row: row(event: nil), liveness: .live([])) == .off(UATOverride.deadText))
        #expect(UATOverride.eligibility(verdict: blocked, row: row(), liveness: .live([])) == .off("worker ended: a capture needs a live worker"))
        #expect(UATOverride.eligibility(verdict: blocked, row: row(), liveness: .unreadable("tmux down")) == .off("tmux down"))
        #expect(UATOverride.eligibility(verdict: blocked, row: row(inbox: nil), liveness: live) == .off("no inbox for this worker"))
        for verdict in [UATGate.Verdict.allowed, .checking, .confirmSkipped(1), .notGated] {
            #expect(UATOverride.eligibility(verdict: verdict, row: row(), liveness: live) == .hidden)
        }
    }
}
