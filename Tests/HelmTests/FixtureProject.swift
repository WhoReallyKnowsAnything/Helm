import Foundation

/// A throwaway project folder holding a fixture `.claude/session-state.db` (scripts/make-fixture-project.sh).
/// The folder lives under `NSTemporaryDirectory()` only. Call `remove()` when done.
struct FixtureProject {
    let path: String
    var dbPath: String { path + "/.claude/session-state.db" }

    /// `name` is the project folder name, so a test can use a space and a `#`. `schema` is "" or "old-schema".
    /// `withDatabase: false` makes the empty folder only.
    static func make(name: String = UUID().uuidString, schema: String = "", withDatabase: Bool = true) throws -> FixtureProject {
        let base = NSTemporaryDirectory() + "gui-test-fx-" + UUID().uuidString.prefix(8).lowercased()
        let path = base + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let fixture = FixtureProject(path: path)
        if withDatabase { try fixture.write(schema: schema) }
        return fixture
    }

    /// The path of the unique folder that `make` created for this fixture.
    private var base: String { (path as NSString).deletingLastPathComponent }

    func remove() { try? FileManager.default.removeItem(atPath: base) }

    /// Runs one statement against the database with the system sqlite3, as the orchestrator does.
    func sql(_ statement: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, statement]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "FixtureProject", code: Int(process.terminationStatus))
        }
    }

    /// Runs the script into this project. It exits non-zero when the database file exists.
    func write(schema: String = "") throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/make-fixture-project.sh").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, path] + (schema.isEmpty ? [] : [schema])
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "FixtureProject", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
    }
}
