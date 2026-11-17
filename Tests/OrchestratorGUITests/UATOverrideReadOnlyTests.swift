import Foundation
import Testing
@testable import OrchestratorGUI

@MainActor @Suite(.serialized) struct UATOverrideReadOnlyTests {
    private func strings(_ value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let list = value as? [Any] { return list.flatMap(strings) }
        if let map = value as? [String: Any] { return map.values.flatMap(strings) }
        return []
    }

    private func modTimes(_ dir: String) -> [String: Date] {
        var result: [String: Date] = [:]
        for case let path as String in FileManager.default.enumerator(atPath: dir) ?? FileManager.default.enumerator(atPath: "/")! {
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir + "/" + path)
            result[path] = attrs?[.modificationDate] as? Date
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

    @Test func theReasonIsPlainTextInOneInboxLineAndNothingElseHappens() async throws {
        let root = NSTemporaryDirectory() + "uat-override-ro-" + UUID().uuidString.prefix(8).lowercased()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.planning/phases/3", withIntermediateDirectories: true)
        try "status: testing\n".write(toFile: root + "/.planning/phases/3/UAT.md", atomically: true, encoding: .utf8)
        _ = try git(["init", "-q"], in: root)
        _ = try git(["add", ".planning"], in: root)
        _ = try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], in: root)
        let inbox = root + "/inbox.jsonl"
        FileManager.default.createFile(atPath: inbox, contents: nil)
        try? FileManager.default.removeItem(atPath: "/tmp/ac5g3")
        let before = modTimes(root + "/.planning")

        let store = UATOverrideStore()
        let row = WorkerRow(agentId: "cad-verify-p3", status: "running", taskTitle: nil, lastEvent: "done",
                            lastActivityAt: "t1", inboxPath: inbox)
        await store.send(reason: "x\n$(touch /tmp/ac5g3)", row: row, eligibility: .on, phase: "3")?.value
        var done = row
        done.lastActivityAt = "t2"
        store.rowsChanged([done], live: ["cad-verify-p3"])
        #expect(store.state == .granted)

        let lines = try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8))
        #expect(strings(object).contains { $0.hasSuffix("x $(touch /tmp/ac5g3)") })
        #expect(!FileManager.default.fileExists(atPath: "/tmp/ac5g3"))
        #expect(try git(["status", "--porcelain", ".planning"], in: root).isEmpty)
        #expect(modTimes(root + "/.planning") == before)
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OrchestratorGUI/" + name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func theNewSourcesStartNoProcessAndWriteNothing() throws {
        let banned = [#"Process\("#, "ProcessRunner", #"/bin/(ba|z)?sh"#, #"system\("#, "popen",
                      "UserDefaults", "AppStorage", #"\.write\("#, "createFile"]
        for name in ["UATOverride.swift", "UATOverrideStore.swift"] {
            let text = try source(name)
            for pattern in banned {
                #expect(text.range(of: pattern, options: .regularExpression) == nil, "\(name) matches \(pattern)")
            }
        }
    }
}
