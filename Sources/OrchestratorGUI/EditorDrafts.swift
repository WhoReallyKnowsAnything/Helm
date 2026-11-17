import CryptoKit
import Foundation

/// D-04: unsaved editor text kept outside the project. One JSON file per edited file, named by the SHA-256 of its real path.
struct EditorDrafts {
    struct Draft: Codable, Equatable {
        var path: String
        var text: String
    }

    let folder: URL

    nonisolated static var defaultFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/OrchestratorGUI/editor-drafts")
    }

    init(folder: URL = EditorDrafts.defaultFolder) { self.folder = folder }

    func file(for path: String) -> URL {
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".json")
    }

    func write(_ text: String, for path: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(Draft(path: path, text: text)).write(to: file(for: path), options: .atomic)
    }

    /// The draft text, or nil when there is none.
    // shortcut: a draft file that does not decode reads as no draft, upgrade if a lost draft proves costly.
    func read(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: file(for: path)),
              let draft = try? JSONDecoder().decode(Draft.self, from: data), draft.path == path else { return nil }
        return draft.text
    }

    func remove(_ path: String) {
        try? FileManager.default.removeItem(at: file(for: path))
    }
}
