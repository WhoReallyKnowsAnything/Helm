import Foundation

/// D-02, D-03: writes the editor text to the file it opened. Read-only access writes nothing.
enum EditorSave {
    enum Outcome: Equatable {
        case saved
        case failed(String)
    }

    /// Atomic UTF-8 write of `text` with no line-ending change. Keeps the file's POSIX permissions. Never creates a file.
    static func write(_ text: String, to url: URL, access: EditorAccess) -> Outcome {
        if case .readOnly(let reason) = access { return .failed("read-only: \(reason)") }
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return .failed("the file no longer exists")
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
