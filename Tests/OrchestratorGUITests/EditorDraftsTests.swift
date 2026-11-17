import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct EditorDraftsTests {
    private func makeFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gui-test-drafts-" + UUID().uuidString)
    }

    @Test func textRoundTripsExactly() {
        let folder = makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let drafts = EditorDrafts(folder: folder)
        for text in ["a\r\nb\r\n", "no final newline", "emoji \u{1F600}\n", "tab\t\"quote\" \\ end"] {
            try? drafts.write(text, for: "/p/a.swift")
            #expect(drafts.read("/p/a.swift") == text)
        }
    }

    @Test func twoPathsGiveTwoFiles() throws {
        let folder = makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let drafts = EditorDrafts(folder: folder)
        try drafts.write("one", for: "/p/a.swift")
        try drafts.write("two", for: "/p/b.swift")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
        #expect(drafts.read("/p/a.swift") == "one" && drafts.read("/p/b.swift") == "two")
    }

    @Test func removeDeletesTheFile() throws {
        let folder = makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let drafts = EditorDrafts(folder: folder)
        try drafts.write("x", for: "/p/a.swift")
        drafts.remove("/p/a.swift")
        #expect(!FileManager.default.fileExists(atPath: drafts.file(for: "/p/a.swift").path))
        #expect(drafts.read("/p/a.swift") == nil)
    }

    @Test func corruptFileReadsAsNil() throws {
        let folder = makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let drafts = EditorDrafts(folder: folder)
        try drafts.write("x", for: "/p/a.swift")
        try Data("not json".utf8).write(to: drafts.file(for: "/p/a.swift"))
        #expect(drafts.read("/p/a.swift") == nil)
    }

    @Test func defaultFolderIsInAppSupportNotATempProject() {
        let path = EditorDrafts.defaultFolder.path
        #expect(path.contains("Application Support/OrchestratorGUI"))
        #expect(!path.hasPrefix(NSTemporaryDirectory()))
    }
}
