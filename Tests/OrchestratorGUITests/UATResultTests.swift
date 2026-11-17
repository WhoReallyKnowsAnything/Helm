import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct UATResultTests {
    private func line(_ kind: UATResult.Kind, _ text: String? = nil, item: String = "3", pending: Int? = 3) -> UATResult.Built {
        UATResult.build(item: item, kind: kind, text: text, firstPending: pending)
    }

    @Test func passIsTheExactLine() {
        #expect(line(.pass) == .line("UAT item 3: pass"))
    }

    @Test func failFlattensNewlineAndKeepsTheDollarText() {
        #expect(line(.fail, "wrong\n$(touch /tmp/ac2)") == .line("UAT item 3: fail - wrong $(touch /tmp/ac2)"))
    }

    @Test func skipAndBlockedUseTheirWords() {
        #expect(line(.skip, "x") == .line("UAT item 3: skip - x"))
        #expect(line(.blocked, "x") == .line("UAT item 3: blocked - x"))
    }

    @Test func emptyAndWhitespaceTextIsRefused() {
        for kind in [UATResult.Kind.fail, .skip, .blocked] {
            for text in ["", "  \n\t ", nil] {
                guard case .refused = line(kind, text) else { Issue.record("not refused: \(kind) \(String(describing: text))"); continue }
            }
        }
    }

    @Test func theCapIsAcceptedWholeAndOneOverIsRefused() {
        let ok = String(repeating: "a", count: 2000), over = String(repeating: "a", count: 2001)
        #expect(line(.fail, ok) == .line("UAT item 3: fail - " + ok))
        guard case .refused = line(.fail, over) else { Issue.record("2001 accepted"); return }
    }

    @Test func onlyTheCurrentPlainItemIsAccepted() {
        guard case .refused = line(.pass, item: "4") else { Issue.record("item 4"); return }
        guard case .refused = line(.pass, item: "3x") else { Issue.record("item 3x"); return }
        guard case .refused = line(.pass, pending: nil) else { Issue.record("no first pending"); return }
    }

    @Test func passDropsTheText() {
        #expect(line(.pass, "note") == .line("UAT item 3: pass"))
    }

    @Test func canSendNeedsNonEmptyCleanedText() {
        #expect(!UATResult.canSend("") && !UATResult.canSend(" \n ") && UATResult.canSend("broken"))
    }

    private func item(_ status: String, reason: String? = nil) -> [UATFile.Item] {
        [UATFile.Item(k: 2, name: "n", expected: "e", status: status, source: nil, reason: reason, reported: nil, other: [])]
    }

    @Test func readbackWaitingRecordedAndMismatch() {
        #expect(UATResult.readback(sent: .pass, item: 2, items: item("pass")) == .recorded(status: "pass", note: nil))
        #expect(UATResult.readback(sent: .pass, item: 2, items: item("pending")) == .waiting)
        #expect(UATResult.readback(sent: .fail, item: 2, items: item("pass")) == .mismatch("sent fail, recorded pass"))
        #expect(UATResult.readback(sent: .skip, item: 2, items: item("skipped", reason: "no device"))
                == .recorded(status: "skipped", note: "no device"))
        #expect(UATResult.readback(sent: .skip, item: 2, items: item("skipped")) == .mismatch("recorded without a reason"))
        #expect(UATResult.readback(sent: .pass, item: 2, items: item("pass")).text == "recorded as pass")
    }
}
