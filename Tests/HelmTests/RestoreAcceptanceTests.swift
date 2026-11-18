import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Helm

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Suite(.serialized) @MainActor struct RestoreAcceptanceTests {
    private func fitting<V: View>(_ view: V, width: CGFloat) -> NSSize {
        let host = NSHostingView(rootView: view.frame(width: width).background(Ink.sidebar).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    // AC1 and AC4: a saved record and no tmux server give a greyed row, and nothing resumes by itself.
    @Test func aSavedRecordWithNoServerIsListedGreyedAndNothingRestores() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "open-projects-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let record = OpenProject(id: "orch-91bc", title: "project-two", folder: "/work/two")
        try JSONEncoder().encode([record]).write(to: file)

        let captures = Calls(), restores = Calls(), refreshes = Calls()
        let model = RestoreModel(
            capture: { captures.add(); return "" },
            restore: { _, _ in restores.add(); return RestoreResult() },
            refresh: { refreshes.add() })

        let open = OpenProjects(file: file)
        let sessions = SessionStore(runner: { .noServer })
        await sessions.refresh()
        let dormant = open.dormant(excluding: sessions.rows)
        #expect(dormant == [record])
        #expect(sessions.rows.isEmpty)

        let now = Date()
        let usage = UsageState(
            fiveHour: UsageWindow(usedPercentage: 8, resetsAt: now.addingTimeInterval(3600), sampled: now),
            sevenDay: UsageWindow(usedPercentage: 45, resetsAt: now.addingTimeInterval(86400), sampled: now))
        for width in [200.0, 260.0] {
            let sidebar = SidebarView(
                newProject: NewProjectView(store: SessionStore(runner: { .failed("") }), onStarted: { _ in }),
                rows: sessions.rows, alertCounts: [:], selected: nil, usage: usage, now: now,
                failure: nil, onSelect: { _ in },
                dormant: dormant)
            let size = fitting(sidebar.frame(height: 480), width: width)
            #expect(size.width > 0 && size.height > 0)
        }

        #expect(captures.total == 0 && restores.total == 0 && refreshes.total == 0)
        await model.press(record)
        #expect(captures.total == 1 && restores.total == 1 && refreshes.total == 1)
    }

    // AC3: against a private tmux server, --resume succeeds only because the launcher ran first.
    @Test func resumeSucceedsOnlyAfterTheLauncherStartedTheBaseSession() throws {
        let tmuxPath = try #require(OrchestratorPaths.tmuxPath())
        let socket = "gui-test-\(UUID().uuidString.prefix(8).lowercased())"
        let tmux = "'\(tmuxPath)' -L \(socket)"
        func privateTmux(_ args: [String]) -> ProcessResult {
            ProcessRunner.run(tmuxPath, ["-L", socket] + args, environment: TmuxRunner.environment(), timeout: 5)
        }
        defer { _ = privateTmux(["kill-server"]) }

        let dir = NSTemporaryDirectory() + "restore-accept-\(UUID().uuidString)"
        let folder = dir + "/project"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func script(_ name: String, _ body: String) throws -> String {
            let path = dir + "/" + name
            try "#!/bin/bash\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        let launcher = try script("launch.sh", """
            \(tmux) new-session -d -s stub-base -n dashboard -c '\(folder)' 'sleep 600' >/dev/null 2>&1 || exit 1
            echo stub-base
            """)
        let dispatch = try script("dispatch.sh", """
            if ! \(tmux) has-session -t =stub-base 2>/dev/null; then
              echo 'Error: --resume refused: the tmux session does not exist' >&2
              exit 1
            fi
            echo 'resumed w1'
            """)

        let early = ProcessRunner.run(
            dispatch, ["--resume"], environment: TmuxRunner.environment(), workingFolder: folder, timeout: 10)
        #expect(early.status == 1)

        let result = try ProjectRestorer.restore(
            folder: folder, envText: "", launcher: launcher, dispatchScript: dispatch, timeout: 20)
        #expect(result.resumed == ["resumed w1"])

        _ = privateTmux(["kill-server"])
        #expect(privateTmux(["list-sessions"]).status != 0)
    }
}
