import Foundation
import Testing
@testable import OrchestratorGUI

@Suite(.serialized) struct ProjectRestorerTests {
    private func tempDir(_ prefix: String) throws -> String {
        let dir = NSTemporaryDirectory() + prefix + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func script(_ path: String, _ body: String) throws {
        try "#!/bin/bash\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Two stub scripts that append one line each to one shared mark file, so the file shows the call order.
    private struct Stubs {
        let folder: String, launcher: String, dispatch: String, mark: String
        var marks: [String] {
            ((try? String(contentsOfFile: mark, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    private func stubs(launcher: String = "echo base-1", dispatch: String = "echo resumed a") throws -> Stubs {
        let dir = try tempDir("restorer-stub-")
        let folder = try tempDir("restorer-folder-")
        let mark = dir + "/mark"
        try script(dir + "/launch.sh", "echo \"launcher $@\" >> '\(mark)'\n\(launcher)")
        try script(
            dir + "/dispatch.sh",
            "echo \"dispatch $@ cwd=$(pwd -P) root=$ORCH_PROJECT_ROOT\" >> '\(mark)'\n\(dispatch)")
        return Stubs(folder: folder, launcher: dir + "/launch.sh", dispatch: dir + "/dispatch.sh", mark: mark)
    }

    private func restore(_ s: Stubs) throws -> RestoreResult {
        try ProjectRestorer.restore(
            folder: s.folder, envText: "", launcher: s.launcher, dispatchScript: s.dispatch, timeout: 10)
    }

    private func reason(_ block: () throws -> Void) -> String? {
        do { try block() } catch { return error.localizedDescription }
        return nil
    }

    @Test func runsTheLauncherThenResumeWithTheSingleArgument() throws {
        let s = try stubs()
        _ = try restore(s)
        let marks = s.marks
        #expect(marks.count == 2)
        #expect(marks[0].hasPrefix("launcher "))
        #expect(marks[1].hasPrefix("dispatch --resume cwd="))
    }

    @Test func launcherReceivesTheGuiFolderFlag() throws {
        let s = try stubs()
        _ = try restore(s)
        #expect(s.marks[0].hasPrefix("launcher --gui-folder \(s.folder) "))
    }

    @Test func resumeRunsInTheProjectFolderWithOrchProjectRoot() throws {
        let s = try stubs()
        _ = try restore(s)
        // pwd -P prints /private/var for a /var temp folder, so match on the unique folder name.
        let leaf = URL(fileURLWithPath: s.folder).lastPathComponent
        #expect(s.marks[1].contains("\(leaf) root="))
        #expect(s.marks[1].hasSuffix("root=\(s.folder)"))
    }

    @Test func aReusedSessionStillResumes() throws {
        let s = try stubs(launcher: "echo base-1\nexit 3")
        _ = try restore(s)
        #expect(s.marks.count == 2)
    }

    @Test func aLauncherFailureThrowsAndResumeNeverRuns() throws {
        let s = try stubs(launcher: "echo no tmux >&2\nexit 1")
        let why = reason { _ = try restore(s) }
        #expect(why == "no tmux")
        #expect(s.marks.count == 1)
    }

    @Test func aResumeFailureThrowsItsStderr() throws {
        let s = try stubs(dispatch: "echo base session is missing >&2\nexit 1")
        let why = reason { _ = try restore(s) }
        #expect(why == "base session is missing")
    }

    @Test func skippedAndResumedLinesComeBackVerbatim() throws {
        let s = try stubs(dispatch: "echo resumed a\necho noise\necho 'skipped b: worktree directory is missing'")
        let result = try restore(s)
        #expect(result.resumed == ["resumed a"])
        #expect(result.skipped == ["skipped b: worktree directory is missing"])
    }

    @Test func nothingToResumeReturnsNoSkippedLines() throws {
        let s = try stubs(dispatch: "echo 'nothing to resume: /work/x'")
        let result = try restore(s)
        #expect(result.skipped.isEmpty)
        #expect(result.resumed.isEmpty)
    }

    @Test func aMissingDispatchScriptThrowsAReason() throws {
        let s = try stubs()
        let why = reason {
            _ = try ProjectRestorer.restore(
                folder: s.folder, envText: "", launcher: s.launcher,
                dispatchScript: s.folder + "/missing.sh", timeout: 10)
        }
        #expect(why?.isEmpty == false)
    }
}
