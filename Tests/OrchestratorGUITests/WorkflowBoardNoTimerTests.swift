import Foundation
import Testing

@Suite struct WorkflowBoardNoTimerTests {
    /// AC2: no board file holds a repeating timer. Files of later plans are scanned once they exist.
    @Test func boardSourcesHoldNoTimer() throws {
        let folder = "Sources/OrchestratorGUI"
        let names = try FileManager.default.contentsOfDirectory(atPath: folder)
        let wanted = Set(names.filter { ($0.hasPrefix("Workflow") || $0.hasPrefix("Cadence")) && $0.hasSuffix(".swift") })
            .union(["WorkerLiveness.swift", "StageRouting.swift"].filter { names.contains($0) })
        #expect(!wanted.isEmpty)
        var offenders: [String] = []
        for name in wanted.sorted() where try String(contentsOfFile: "\(folder)/\(name)", encoding: .utf8).contains("Timer") {
            offenders.append(name)
        }
        #expect(offenders.isEmpty, "Timer found in \(offenders). Scanned: \(wanted.sorted())")
    }
}
