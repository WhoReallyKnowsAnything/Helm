import CryptoKit
import Foundation
import Testing
@testable import Helm

/// D-02 of phase 2: the board marks a row for a live hold on its own stage label and has no decision control.
struct WorkflowBoardHoldTests {
    private static let op = "Bash: git push origin main"
    private static let hash = SHA256.hash(data: Data(op.utf8)).map { String(format: "%02x", $0) }.joined()

    private static func hold(_ label: String, live: Bool = true, decided: Bool = false, tampered: Bool = false) -> GateHold? {
        let text = tampered ? "Bash: git push --force" : op
        let pending = Data("\(label)\n\(hash)\n4242\n100\n/fx\nThu Jan 1 00:00:00 2026\n\(text)".utf8)
        let decision = decided ? Data("allow \(hash)".utf8) : nil
        return GateHold.parse(id: "h-\(label)", pending: pending, decision: decision, isHookLive: { _, _ in live })
    }

    private static func marked(_ holds: [GateHold]) -> [String] {
        WorkflowBoardFixture.rows.map(\.n).filter { !WorkflowBoardRows.holds(holds, phase: $0).isEmpty }
    }

    @Test func onlyALiveHoldOnItsOwnStageLabelMarksARow() throws {
        let label = WorkflowDispatch.label(stage: .execute, phase: "3")
        let live = try #require(Self.hold(label))
        #expect(live.state == .live)
        #expect(Self.marked([live]) == ["3"])

        let others: [GateHold?] = [
            Self.hold(label, decided: true), Self.hold(label, live: false), Self.hold(label, tampered: true),
            Self.hold("cad-execute-p1-1"), Self.hold("cad-config"),
        ]
        let states = try others.map { try #require($0).state }
        #expect(states == [.decided, .ghost, .tampered, .live, .live])
        for other in others { #expect(Self.marked([try #require(other)]).isEmpty) }
    }

    @Test func theBoardSourceHasNoApproveOrDenyControl() throws {
        for path in ["Sources/Helm/WorkflowBoardView.swift", "Sources/Helm/DesignKit/Components/BoardRows.swift"] {
            // Comment lines state the rule (D-02), so only code lines count.
            let text = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
                .filter { !$0.drop(while: \.isWhitespace).hasPrefix("//") }.joined(separator: "\n")
            for word in ["Approve", "Deny", "onDecide", "HoldChoice"] {
                #expect(!text.contains(word), "\(path) contains \(word)")
            }
        }
    }
}
