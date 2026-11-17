import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct OrchestratorRuntimeTests {
    private let fm = FileManager.default

    private func scratch() throws -> (runtime: OrchestratorRuntime, root: URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString)")
        let src = root.appendingPathComponent("bundle/orchestration")
        try fm.createDirectory(at: src.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try "echo a\n".write(to: src.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try "echo b\n".write(to: src.appendingPathComponent("lib/x.sh"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("run.sh").path)
        let home = root.appendingPathComponent("Application Support/Helm")
        return (OrchestratorRuntime(source: src, destination: home.appendingPathComponent("orchestration"),
                                    stamp: home.appendingPathComponent(".orchestration.stamp")), root)
    }

    private func mtime(_ url: URL) throws -> Date {
        try #require(fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    @Test func firstRunCopiesEveryFileAndKeepsExecBits() throws {
        let (rt, root) = try scratch()
        defer { try? fm.removeItem(at: root) }
        #expect(rt.sync())
        #expect(fm.isExecutableFile(atPath: rt.destination.appendingPathComponent("run.sh").path))
        #expect(!fm.isExecutableFile(atPath: rt.destination.appendingPathComponent("lib/x.sh").path))
        #expect(try String(contentsOf: rt.destination.appendingPathComponent("lib/x.sh"), encoding: .utf8) == "echo b\n")
        #expect(fm.fileExists(atPath: rt.stamp.path))
    }

    @Test func secondRunChangesNoMtime() throws {
        let (rt, root) = try scratch()
        defer { try? fm.removeItem(at: root) }
        #expect(rt.sync())
        let file = rt.destination.appendingPathComponent("run.sh")
        let before = (try mtime(file), try mtime(rt.stamp), try mtime(rt.destination))
        Thread.sleep(forTimeInterval: 1.1)
        #expect(rt.sync())
        #expect(try mtime(file) == before.0)
        #expect(try mtime(rt.stamp) == before.1)
        #expect(try mtime(rt.destination) == before.2)
    }

    @Test func changedBundledFileReplacesTheRuntimeFile() throws {
        let (rt, root) = try scratch()
        defer { try? fm.removeItem(at: root) }
        #expect(rt.sync())
        try "echo changed\n".write(to: rt.source.appendingPathComponent("lib/x.sh"), atomically: true, encoding: .utf8)
        #expect(rt.sync())
        #expect(try String(contentsOf: rt.destination.appendingPathComponent("lib/x.sh"), encoding: .utf8) == "echo changed\n")
    }

    @Test func failedCopyKeepsTheOldCopyAndStamp() throws {
        let (rt, root) = try scratch()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rt.source.appendingPathComponent("lib/x.sh").path)
            try? fm.removeItem(at: root)
        }
        #expect(rt.sync())
        let oldStamp = try String(contentsOf: rt.stamp, encoding: .utf8)
        try "echo new\n".write(to: rt.source.appendingPathComponent("lib/x.sh"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rt.source.appendingPathComponent("lib/x.sh").path)
        #expect(!rt.sync())
        #expect(try String(contentsOf: rt.stamp, encoding: .utf8) == oldStamp)
        #expect(try String(contentsOf: rt.destination.appendingPathComponent("lib/x.sh"), encoding: .utf8) == "echo b\n")
    }

    @Test func missingBundleResourceDoesNothing() {
        // swift test has no bundled orchestration resource.
        #expect(!OrchestratorRuntime.syncBundled())
    }
}
