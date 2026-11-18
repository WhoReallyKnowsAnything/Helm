import Foundation
import Testing
@testable import Helm

@MainActor @Suite(.serialized) struct ExecuteReadOnlyTests {
    private func modTimes(_ dir: String) -> [String: Date] {
        var result: [String: Date] = [:]
        for case let path as String in FileManager.default.enumerator(atPath: dir) ?? FileManager.default.enumerator(atPath: "/")! {
            // Cadence's own per-call lock: made and removed inside each planning.mjs run, and a watcher-triggered reload can still be running.
            if path == "layout-migration.lock" { continue }
            result[path] = (try? FileManager.default.attributesOfItem(atPath: dir + "/" + path))?[.modificationDate] as? Date
        }
        return result
    }

    private func git(_ args: [String], in dir: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func put(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func loadingTheScreenCreatesAndChangesNothingUnderPlanning() async throws {
        let root = NSTemporaryDirectory() + "exec-ro-" + UUID().uuidString.prefix(8).lowercased()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let phase = root + "/.planning/phases/1"
        let plan = "---\nphase: 1\nplan: %d\nfiles:\n  - a%d.txt\n---\n# Phase 1: x - Plan %d: y\n"
        try put(phase + "/PLAN-1.md", String(format: plan, 1, 1, 1))
        try put(phase + "/PLAN-2.md", String(format: plan, 2, 2, 2))
        try put(phase + "/records/reports/plan-1.md", "PLAN PARTIAL\n| Task | Commit | Note |\n|---|---|---|\n| 1 a | abc1234 | n |\n")
        _ = try git(["init", "-q"], in: root)
        _ = try git(["add", ".planning"], in: root)
        _ = try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], in: root)
        let before = modTimes(root + "/.planning")

        let store = ExecuteScreenStore()
        store.point(project: root, phase: "1", worktree: nil)
        // Wait on the clock, not an iteration count: under suite load each sleep can run long or the node load can be slow.
        let deadline = ContinuousClock.now + .seconds(60)
        while store.data.source == .none, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.data.source == .project)
        #expect(modTimes(root + "/.planning") == before)
        #expect(try git(["status", "--porcelain", ".planning", ":!.planning/layout-migration.lock"], in: root).isEmpty)
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Helm/" + name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func theExecuteSourcesCallNoWriteApi() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Helm").path
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("Execute") && $0.hasSuffix(".swift") }
        #expect(names.count >= 6)
        let banned = [#"\.write\("#, "createFile", "createDirectory", "removeItem", "moveItem", "copyItem",
                      #"FileHandle\(forWriting"#, "UserDefaults", "AppStorage"]
        for name in names {
            let text = try source(name)
            for pattern in banned {
                #expect(text.range(of: pattern, options: .regularExpression) == nil, "\(name) matches \(pattern)")
            }
        }
    }
}
