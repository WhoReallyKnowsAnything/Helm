import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct EditorSaveTests {
    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gui-test-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writtenBytesEqualTheTextBytes() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        for text in ["a\r\nb\r\n", "no final newline", "emoji \u{1F600} end\n"] {
            #expect(EditorSave.write(text, to: file, access: .editable) == .saved)
            #expect(try Data(contentsOf: file) == Data(text.utf8))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.txt"])
    }

    @Test func permissionsSurviveTheWrite() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("run.sh")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(EditorSave.write("new", to: file, access: .editable) == .saved)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
    }

    @Test func readOnlyAccessWritesNothing() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PLAN.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let outcome = EditorSave.write("new", to: file, access: .readOnly("Cadence owns the files under .planning"))
        guard case .failed = outcome else { Issue.record("expected a refusal"); return }
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == before)
    }

    @Test func unwritableFolderFailsAndKeepsTheOldBytes() throws {
        let dir = try makeDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let file = dir.appendingPathComponent("a.txt")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        guard case .failed(let reason) = EditorSave.write("new", to: file, access: .editable) else {
            Issue.record("expected a failure"); return
        }
        #expect(!reason.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
    }

    @Test func missingFileIsNotCreated() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("gone.txt")
        guard case .failed = EditorSave.write("x", to: file, access: .editable) else { Issue.record("expected a failure"); return }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
