import Foundation
import Testing
@testable import Helm

@Suite struct UATFileTests {
    private let head = "---\nstatus: testing\nphase: 6\nfields_version: 1\nstarted: 2026-10-30\nupdated: 2026-10-31\n---\n\n## Items\n\n"
    private let tail = "\n## Summary\n\ntotal: 6\npassed: 4\nfailed: 0\npending: 0\nskipped: 2\nblocked: 0\nreworked: 1\n"

    private var sample: String {
        head + """
        ### 1. Status-line tap install and CLAUDE_GUI hiding: both modes
        expected: Pressing Install... leaves a backup of ~/.claude/settings.json and changes only statusLine.command.
        criterion: AC1
        status: pass
        first_pass: fail
        source: verifier
        reported: 4 screenshots: CLAUDE_GUI=1 shows no status line.
        severity: minor
        reason: Fixed by orchestrator launch mode env (orchestrator main ddf3d81).

        ### 2. Node shows model
        expected: Each node shows the context % and `model · effort`.
        status: pass
        reported: yes it switches model

        ### 3. Usage panel matches /usage
        expected: The panel shows 5-hour and 7-day % and they match.
        status: pass
        source: verifier

        ### 4. Look at Sources/a.swift
        expected: See Sources/a.swift open in the editor
        status: fail
        reported: it does not open

        ### 5. Compare the usage panel
        expected: percentages match
        origin: verifier
        why_human: Needs a live Claude account.
        status: skipped
        reason: Duplicate of an existing item; walked there instead.

        ### 6. Blocked check
        expected: something
        status: blocked
        reason: no device

        """ + tail
    }

    private func items(_ text: String) -> [UATFile.Item] {
        guard case .items(let list) = UATFile.parse(text) else { Issue.record("unsupported"); return [] }
        return list
    }

    @Test func itemsParseInOrderWithNumbers() {
        let list = items(sample)
        #expect(list.map(\.k) == [1, 2, 3, 4, 5, 6])
        #expect(list.map(\.status) == ["pass", "pass", "pass", "fail", "skipped", "blocked"])
    }

    @Test func sourceAndNoteFollowTheRules() {
        let list = items(sample)
        #expect(list[2].source == "verifier")
        #expect(list[1].source == nil)
        #expect(list[0].note == "Fixed by orchestrator launch mode env (orchestrator main ddf3d81).")
        #expect(list[1].note == "yes it switches model")
        #expect(list[3].note == "it does not open")
        #expect(list[4].note == "Duplicate of an existing item; walked there instead.")
        #expect(list[5].note == "no device")
    }

    @Test func nameWithColonAndExpectedWithPathStayWhole() {
        let list = items(sample)
        #expect(list[0].name == "Status-line tap install and CLAUDE_GUI hiding: both modes")
        #expect(list[3].expected == "See Sources/a.swift open in the editor")
        #expect(list[1].expected == "Each node shows the context % and `model · effort`.")
    }

    @Test func otherFieldsAreKeptRaw() {
        let list = items(sample)
        #expect(list[0].other.contains("criterion: AC1") && list[0].other.contains("severity: minor"))
        #expect(list[4].other.contains("why_human: Needs a live Claude account."))
    }

    @Test func summaryAndHandAddedSectionsAreNotItems() {
        let text = head + "### 1. One\nexpected: e\nstatus: pending\n\n### Manual notes\n1. check the logs\nstatus: pass\n" + tail
        let list = items(text)
        #expect(list.count == 1 && list[0].status == "pending")
    }

    @Test func otherFieldsVersionIsUnsupportedWithNoItems() {
        let text = sample.replacingOccurrences(of: "fields_version: 1", with: "fields_version: 2")
        #expect(UATFile.parse(text) == .unsupported(version: "2"))
        #expect(UATFile.parse("no front matter") == .unsupported(version: "missing"))
    }

    @Test func realArchivesParseWhenPresent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent(".planning/_archive-v1/6/UAT.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let list = items(text)
        #expect(list.map(\.k) == Array(1...10))
        #expect(list[2].source == nil && list[1].source == "verifier")
        #expect(list[8].status == "skipped" && list[8].reason != nil)
    }
}
