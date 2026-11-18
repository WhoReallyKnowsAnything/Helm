import CryptoKit
import Foundation
import Testing
@testable import Helm

/// The pure part: no disk, no `ps`. Liveness is a closure.
@Suite struct GateHoldTests {
    private func hex(_ op: String) -> String {
        SHA256.hash(data: Data(op.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func pending(
        label: String = "bravo", hash: String? = nil, pid: String = "4242", epoch: String = "100",
        started: String = "Thu Jan 1 00:00:00 2026", op: String = "Bash: git push origin main", header: Int = 6
    ) -> Data {
        let lines = [label, hash ?? hex(op), pid, epoch, "/fx", started].prefix(header).map { $0 + "\n" }.joined()
        return Data((lines + op).utf8)
    }

    private func parse(
        _ data: Data, id: String = "toolu_A", decision: String? = nil, live: Bool = true
    ) -> GateHold? {
        GateHold.parse(id: id, pending: data, decision: decision.map { Data($0.utf8) }, isHookLive: { _, _ in live })
    }

    private let op = "Bash: git push origin main"

    @Test func aLiveHookWithAMatchingHashIsLive() throws {
        let hold = try #require(parse(pending()))
        #expect(hold.state == .live)
        #expect(hold.label == "bravo")
        #expect(hold.hash == hex(op))
        #expect(hold.command == op)
        #expect(hold.epoch == 100)
        #expect(hold.key == "gate:toolu_A:\(hex(op))")
    }

    @Test func theLivenessCheckGetsTheHookPidAndStartTime() throws {
        var asked: (Int32, String)?
        _ = GateHold.parse(id: "x", pending: pending(pid: "77", started: "Mon Jun 2 03:04:05 2025"), decision: nil,
                           isHookLive: { asked = ($0, $1); return true })
        #expect(asked?.0 == 77)
        #expect(asked?.1 == "Mon Jun 2 03:04:05 2025")
    }

    @Test(arguments: ["allow", "deny"]) func aValidDecisionGivesDecided(choice: String) throws {
        #expect(try #require(parse(pending(), decision: "\(choice) \(hex(op))")).state == .decided)
        #expect(try #require(parse(pending(), decision: "\(choice) \(hex(op))\n")).state == .decided)
    }

    @Test func aDecidedHoldWinsOverAGhostAndATamperedOne() throws {
        let tampered = pending(hash: hex(op), op: "Bash: rm -rf /")
        #expect(try #require(parse(tampered, decision: "allow \(hex(op))", live: false)).state == .decided)
    }

    @Test func aDeadHookGivesGhost() throws {
        #expect(try #require(parse(pending(), live: false)).state == .ghost)
    }

    @Test(arguments: ["0", "1", "01", "-5", "abc", "", "4294967296", "99999999999"])
    func aBadPidIsGhostWithoutAskingTheCheck(pid: String) throws {
        var asked = false
        let hold = GateHold.parse(id: "x", pending: pending(pid: pid), decision: nil, isHookLive: { _, _ in asked = true; return true })
        #expect(try #require(hold).state == .ghost)
        #expect(!asked)
    }

    @Test func opTextChangedAfterHashingGivesTampered() throws {
        #expect(try #require(parse(pending(hash: hex(op), op: "Bash: git push --force"))).state == .tampered)
    }

    @Test(arguments: ["", "abc", "ABCDEF" + String(repeating: "0", count: 58), String(repeating: "g", count: 64)])
    func aMalformedHashLineGivesTampered(hash: String) throws {
        #expect(try #require(parse(pending(hash: hash))).state == .tampered)
    }

    @Test func aDecisionThatIsNotExactStaysLive() throws {
        let h = hex(op)
        for decision in ["allow \(h)\r\n", "allow \(h)\n\n", "ALLOW \(h)", "Allow \(h)", "allow \(String(h.dropLast()))",
                         "allow \(String(repeating: "0", count: 64))", "allow \(h) extra", " allow \(h)", "allow  \(h)",
                         "allow\t\(h)", "deny", ""] {
            #expect(try #require(parse(pending(), decision: decision)).state == .live, "\(decision.debugDescription)")
        }
    }

    @Test func aHashOverMultiLineOpTextWithATrailingNewlineStillMatches() throws {
        let multi = "Bash: git commit -m 'a\nb'\n"
        let hold = try #require(parse(pending(op: multi)))
        #expect(hold.state == .live)
        #expect(hold.command == "Bash: git commit -m 'a\\nb'\\n")
    }

    @Test func controlAndBidiCharactersAreShownAsEscapesNotRemoved() throws {
        let nasty = "Bash: ls\u{1B}[31m \u{202E}evil\u{2066}x\u{200B}\r\u{7}end\ttab"
        let hold = try #require(parse(pending(op: nasty)))
        #expect(hold.state == .live)
        #expect(hold.command == "Bash: ls\\u{1B}[31m \\u{202E}evil\\u{2066}x\\u{200B}\\r\\u{7}end\\ttab")
    }

    @Test func aLongCommandStaysWholeAndLive() throws {
        let hold = try #require(parse(pending(op: "Bash: " + String(repeating: "a", count: 5000))))
        #expect(hold.state == .live)
        #expect(hold.command.count == 5006 && !hold.command.hasSuffix("..."))
    }

    @Test func aHarmfulPartAfterPaddingIsInTheText() throws {
        let padded = "Bash: echo hi" + String(repeating: " ", count: 400) + "\n\n\n\t\t" + String(repeating: " ", count: 400) + "rm -rf ~"
        let hold = try #require(parse(pending(op: padded)))
        #expect(hold.state == .live)
        #expect(hold.command.hasSuffix("rm -rf ~"))
        #expect(hold.command.contains("\\n\\n\\n\\t\\t"))
    }

    @Test func anIdOrLabelThatFailsItsPatternIsSkipped() {
        for id in ["", "a.b", "a b", "a/b", "../x", String(repeating: "a", count: 129), "é"] {
            #expect(parse(pending(), id: id) == nil, "\(id)")
        }
        #expect(parse(pending(), id: String(repeating: "a", count: 128)) != nil)
        #expect(parse(pending(), id: "perm-1_A-b") != nil)
        for label in ["", "-x", "a b", "a/b", "a\u{0}b", "é", "x\r"] {
            #expect(parse(pending(label: label)) == nil, "\(label.debugDescription)")
        }
        for label in [".hidden", "_x", "a-b.c_d", "0"] {
            #expect(parse(pending(label: label)) != nil, "\(label)")
        }
    }

    @Test func aFileWithFewerThanSixHeaderLinesIsSkipped() {
        #expect(parse(pending(header: 5)) == nil)
        #expect(parse(Data()) == nil)
    }

    @Test func onlyAHoldThatCannotBeAnsweredHasAStateLine() throws {
        #expect(try #require(parse(pending())).stateLine == nil)
        #expect(try #require(parse(pending(), decision: "allow \(hex(op))")).stateLine == "decided")
        #expect(try #require(parse(pending(), live: false)).stateLine == "hook ended")
        #expect(try #require(parse(pending(hash: hex(op), op: "Bash: other"))).stateLine == "tampered hold")
    }

    @Test func holdsAreOrderedByEpochThenIdWithANonNumericEpochLast() throws {
        let holds = try ["200", "100", "x", "100", "-1"].enumerated().map { index, epoch in
            try #require(parse(pending(epoch: epoch), id: "id\(index)"))
        }
        #expect(holds.sorted(by: GateHold.isOrderedBefore).map(\.id) == ["id1", "id3", "id0", "id2", "id4"])
    }
}
