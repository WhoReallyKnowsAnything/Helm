import Foundation
import Testing
@testable import Helm

/// D-01 of phase 2: a phase-scoped row chip sends the same board line as the chip table builds, in 1 press.
@MainActor
struct WorkflowBoardChipTests {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var off: String?
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        func add(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
    }

    private static let phaseSkills = ["/cadence:cad-coverage", "/cadence:cad-minimalism-review", "/cadence:cad-decision-review"]

    private func started(_ probe: Probe, defaults: UserDefaults) async -> WorkflowStore {
        let store = WorkflowStore(
            source: { _ in .success(WorkflowBoardFixture.board) },
            liveness: { _ in probe.off },
            routing: StageRouting(defaults: defaults),
            makeDeliver: { _ in { probe.add($0); return .sent } })
        store.point(at: "/p", base: "base")
        for _ in 0..<300 where store.panel == nil { try? await Task.sleep(for: .milliseconds(10)) }
        return store
    }

    @Test func eachRowChipSendsTheChipTableLine() async throws {
        let defaults = UserDefaults(suiteName: "WorkflowBoardChipTests.\(UUID().uuidString)")!
        let probe = Probe()
        let store = await started(probe, defaults: defaults)
        let row = WorkflowBoardRows.splitChips(WorkflowBoardFixture.chips, rows: WorkflowBoardFixture.rows).onRows.values.joined()
        #expect(row.map(\.skill).sorted() == Self.phaseSkills.sorted())
        let utility = StageRouting(defaults: defaults).utilityEntry()
        var expected: [String] = []
        for chip in row {
            expected.append(try WorkflowDispatch.chipLine(skill: chip.skill, phase: chip.phase, argument: chip.argument,
                                                          routing: utility).get())
            await store.pressChip(chip)
            #expect(probe.lines == expected, "\(chip.skill) did not send its chip-table line in 1 press")
        }
        #expect(probe.lines.count == 3)
    }

    @Test func chipsOffBlocksThePressAndSendsNothing() async {
        let probe = Probe()
        probe.off = "No orchestrator window."
        let store = await started(probe, defaults: UserDefaults(suiteName: "WorkflowBoardChipTests.\(UUID().uuidString)")!)
        for chip in WorkflowBoardFixture.chips { await store.pressChip(chip) }
        #expect(store.panel?.chipsOff != nil)
        #expect(probe.lines.isEmpty)
    }

    @Test func theMenuHoldsOnlyTheProjectWideChips() {
        let extra = ["/cadence:cad-health", "/cadence:cad-audit"].map { CadenceChip(skill: $0, phase: nil, argument: nil, rule: "r") }
        let menu = WorkflowBoardRows.splitChips(WorkflowBoardFixture.chips + extra, rows: WorkflowBoardFixture.rows).menu
        #expect(Set(menu.map(\.skill)) == ["/cadence:cad-suggest", "/cadence:cad-health", "/cadence:cad-audit"])
        #expect(menu.count == 3)
    }
}
