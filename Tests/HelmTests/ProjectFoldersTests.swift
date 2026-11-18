import Foundation
import Testing
@testable import Helm

struct ProjectFoldersTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func listsOnlyVisibleFoldersSortedByName() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["gamma", "alpha", "Beta", ".cache"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        let found = ProjectFolders.list(root: root.path)
        #expect(found == ["alpha", "Beta", "gamma"].map { root.appendingPathComponent($0).path })
    }

    @Test func aMissingRootGivesAnEmptyList() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")
        #expect(ProjectFolders.list(root: missing.path).isEmpty)
    }
}
