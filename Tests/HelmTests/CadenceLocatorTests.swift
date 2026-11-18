import Foundation
import Testing
@testable import Helm

@Suite struct CadenceLocatorTests {
    private func makeInstall(_ root: URL, _ name: String, scripts: Bool = true) throws -> String {
        let bin = root.appendingPathComponent("\(name)/cadence-core/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if scripts {
            for file in ["planning.mjs", "config.mjs"] {
                try "".write(to: bin.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
        }
        return root.appendingPathComponent(name).path
    }

    private func writePlugins(_ file: URL, installPath: String?) throws {
        let entry = installPath.map { #"[{"scope":"user","installPath":"\#($0)"}]"# } ?? "[]"
        try #"{"plugins":{"cadence@cadence":\#(entry)}}"#.write(to: file, atomically: true, encoding: .utf8)
    }

    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func nodeAbsentGivesReasonNamingTheList() throws {
        let dir = try temp()
        let result = CadenceLocator.locate(pluginsFile: dir.path + "/none.json", nodeSearchPath: dir.path)
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.reason.contains(dir.path))
        #expect(failure.reason.contains("node"))
    }

    @Test func missingEntryGivesReason() throws {
        let dir = try temp()
        let file = dir.appendingPathComponent("p.json")
        try writePlugins(file, installPath: nil)
        guard case .failure(let failure) = CadenceLocator.locate(pluginsFile: file.path) else { Issue.record("expected failure"); return }
        #expect(failure.reason.contains("cadence@cadence"))
    }

    @Test func missingScriptGivesReason() throws {
        let dir = try temp()
        let install = try makeInstall(dir, "a", scripts: false)
        let file = dir.appendingPathComponent("p.json")
        try writePlugins(file, installPath: install)
        guard case .failure(let failure) = CadenceLocator.locate(pluginsFile: file.path) else { Issue.record("expected failure"); return }
        #expect(failure.reason.contains("planning.mjs"))
    }

    @Test func editedJsonGivesTheOtherInstallOnTheNextCall() throws {
        let dir = try temp()
        let one = try makeInstall(dir, "one")
        let two = try makeInstall(dir, "two")
        let file = dir.appendingPathComponent("p.json")
        try writePlugins(file, installPath: one)
        let first = try CadenceLocator.locate(pluginsFile: file.path).get()
        try writePlugins(file, installPath: two)
        let second = try CadenceLocator.locate(pluginsFile: file.path).get()
        #expect(first.planning == one + "/cadence-core/bin/planning.mjs")
        #expect(second.planning == two + "/cadence-core/bin/planning.mjs")
        #expect(second.config == two + "/cadence-core/bin/config.mjs")
        #expect(second.node.hasSuffix("/node"))
    }
}
