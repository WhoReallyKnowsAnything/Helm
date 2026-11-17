import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct CadenceHealthTests {
    private func status(drift: Int, outstanding: Int) -> CadenceStatus {
        CadenceStatus(current: "1", total: 1, cycle: nil, phases: [], cursorNext: nil, drift: drift, outstanding: outstanding)
    }

    private let clean: Result<CadenceConfig.Audit, CadenceLocator.Failure> = .success(.init(total: 5, broken: 0, kinds: []))

    @Test func statusFillsDriftAndOutstandingInOrder() {
        let health = CadenceHealth(status: status(drift: 2, outstanding: 3), audit: clean)
        #expect(health.lines.map(\.label) == ["drift", "audit", "outstanding plans", "open debug files", "open capture todos"])
        #expect(health.lines.map(\.text) == ["2", "0/5", "3", "0", "0"])
    }

    @Test func captureTodosReadTheTodosBullets() throws {
        let todos = #"{"ok":true,"exists":true,"sections":[{"heading":"Seeds","bullets":4},{"heading":"Todos","bullets":2}]}"#
        #expect(try CadenceHealth.parseCaptureTodos(todos).get() == 2)
        #expect(try CadenceHealth.parseCaptureTodos(#"{"ok":true,"sections":[{"heading":"Seeds","bullets":4}]}"#).get() == 0)
        #expect(try CadenceHealth.parseCaptureTodos(#"{"ok":true,"exists":false,"sections":[]}"#).get() == 0)
    }

    @Test func captureFailureAndGarbageGiveAReason() {
        for text in [#"{"ok":false,"reason":"bad"}"#, "garbage", #"{"ok":true}"#] {
            guard case .failure = CadenceHealth.parseCaptureTodos(text) else { Issue.record("expected failure for \(text)"); return }
        }
    }

    private func debugFolder(_ files: [String: String]) throws -> String {
        let root = NSTemporaryDirectory() + "debug-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/.planning/debug", withIntermediateDirectories: true)
        for (name, text) in files { try text.write(toFile: root + "/.planning/debug/" + name, atomically: true, encoding: .utf8) }
        return root
    }

    @Test func openDebugFilesFollowCadencesRule() throws {
        let root = try debugFolder([
            "a.md": "Status: resolved\nx", "b.md": "# t\nStatus: open\n", "c.md": "no status here",
            "d.md": "Status:   resolved   \n", "notes.txt": "Status: open"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try CadenceHealth.openDebugFiles(project: root).get() == 2)
    }

    @Test func missingDebugFolderGivesZero() throws {
        #expect(try CadenceHealth.openDebugFiles(project: NSTemporaryDirectory() + "none-" + UUID().uuidString).get() == 0)
    }

    @Test func unreadableDebugFileGivesAReason() throws {
        let root = try debugFolder(["a.md": "Status: open"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = root + "/.planning/debug/a.md"
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file) }
        guard case .failure(let problem) = CadenceHealth.openDebugFiles(project: root) else { Issue.record("expected failure"); return }
        #expect(problem.reason.contains("a.md"))
    }

    @Test func aFailedCellShowsItsReasonAndLeavesTheOthersAlone() {
        let health = CadenceHealth(drift: .failure(.init(reason: "no node")), audit: .failure(.init(reason: "audit broke")), outstanding: .success(0))
        #expect(health.lines.map(\.text) == ["no node", "audit broke", "0", "0", "0"])
        #expect(health.lines[1].warning == false)
    }

    @Test func brokenAuditShowsKindsAndWarns() throws {
        let rows = (0..<8).map { _ in #"{"id":"A","break":"no-plan"}"# } + (0..<4).map { _ in #"{"id":"B","break":"not-verified"}"# }
        let json = #"{"ok":true,"counts":{"total":12,"traced":0,"broken":12,"deferred":0},"requirements":[\#(rows.joined(separator: ","))]}"#
        let audit = CadenceConfig.parseAuditCounts(json)
        let line = CadenceHealth(status: status(drift: 0, outstanding: 0), audit: audit).lines[1]
        #expect(line.text == "12/12 no-plan, not-verified")
        #expect(line.warning)
    }

    @Test func zeroBrokenHasNoKindsAndNoWarning() {
        let audit = CadenceConfig.parseAuditCounts(#"{"ok":true,"counts":{"total":7,"broken":0},"requirements":[{"id":"A","status":"Complete"}]}"#)
        let line = CadenceHealth(status: status(drift: 0, outstanding: 0), audit: audit).lines[1]
        #expect(line.text == "0/7")
        #expect(!line.warning)
    }

    @Test func auditFailureGivesAReasonAndG4StillReadsBroken() {
        guard case .failure = CadenceConfig.parseAuditCounts(#"{"ok":false,"reason":"no-planning-dir"}"#) else { Issue.record("expected failure"); return }
        #expect((try? CadenceConfig.parseAudit(#"{"ok":true,"counts":{"total":2,"broken":1}}"#).get()) == 1)
    }
}
