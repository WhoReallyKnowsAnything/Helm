import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct OrchestratorPathsTests {
    @Test func tmuxPathIsAbsoluteAndExecutable() throws {
        let tmux = try #require(OrchestratorPaths.tmuxPath())
        #expect(tmux.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: tmux))
    }


    @Test func nodePathFollowsTheGivenListOrder() throws {
        let node = try #require(OrchestratorPaths.nodePath())
        #expect(node.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: node))
        #expect(OrchestratorPaths.nodePath(searchPath: "/nonexistent-dir") == nil)
    }

    @Test func bundledAppUsesTheApplicationSupportCopy() throws {
        let res = FileManager.default.temporaryDirectory.appendingPathComponent("res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: res.appendingPathComponent("orchestration"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: res) }
        let support = URL(fileURLWithPath: "/tmp/fake-support")
        #expect(OrchestratorPaths.orchestratorRoot(bundleResourceURL: res, applicationSupport: support) == "/tmp/fake-support/Helm")
    }

    @Test func unbundledRunUsesTheRepoCheckout() {
        let root = OrchestratorPaths.orchestratorRoot(bundleResourceURL: nil, applicationSupport: URL(fileURLWithPath: "/tmp/fake-support"))
        #expect(FileManager.default.fileExists(atPath: root + "/orchestration/lib/tmux-session.sh"))
    }

    @Test func libraryFileExists() {
        #expect(FileManager.default.fileExists(atPath: OrchestratorPaths.orchestratorRepo + "/orchestration/lib/tmux-session.sh"))
    }


    @Test func libraryPrintsAttachStringForEachLabel() throws {
        let tmux = try #require(OrchestratorPaths.tmuxPath())
        let dashboard = try printAttach(label: "dashboard")
        #expect(dashboard.hasPrefix(tmux))
        #expect(dashboard.contains("-s gui-test-x-dashboard"))
        let worker = try printAttach(label: "worker-1")
        #expect(worker.contains("-s gui-test-x-worker-1"))
        #expect(!worker.contains("gui-test-x-dashboard"))
    }

    /// Sources the library under `env -i` with only the fixed PATH and prints the attach string.
    private func printAttach(label: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["-i", "PATH=\(OrchestratorPaths.searchPath)", "/bin/bash", "-c",
                       #"source "$1" && tmux_client_attach_cmd "$2" "$3""#,
                       "bash", OrchestratorPaths.orchestratorRepo + "/orchestration/lib/tmux-session.sh", "gui-test-x", label]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
