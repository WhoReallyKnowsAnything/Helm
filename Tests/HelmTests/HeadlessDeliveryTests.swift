import Foundation
import Testing
@testable import Helm

/// AC6: the real orchestrator launcher on a private tmux server, a stub `claude`, and `InboxDelivery.deliver`
/// into the inbox the launcher stored. Needs the orchestrator repo (Plans 1 and 2) next to this one.
@Suite(.serialized) struct HeadlessDeliveryTests {
    private static let launcher = OrchestratorPaths.orchestratorRepo + "/orchestration/launch-claude.sh"

    private func shell(_ command: String, in dir: String, env: [String: String], timeout: TimeInterval = 90) -> ProcessResult {
        ProcessRunner.run("/bin/bash", ["-c", command], environment: env, workingFolder: dir, timeout: timeout)
    }

    private func lines(_ path: String) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func userContent(_ line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "user", let message = object["message"] as? [String: Any] else { return nil }
        return message["content"] as? String
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: HeadlessDeliveryTests.launcher)))
    @MainActor func threeMessagesReachTheStubAndTheInboxInOrder() async throws {
        let socket = "gui-test-\(UUID().uuidString.prefix(8).lowercased())"
        let root = NSTemporaryDirectory() + "gui-test-hd-" + UUID().uuidString.prefix(8).lowercased()
        let home = root + "/home", stub = root + "/stub", project = root + "/proj-hd"
        for dir in [home, stub, project] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let received = root + "/received"
        defer {
            if let tmux = OrchestratorPaths.tmuxPath() {
                _ = ProcessRunner.run(tmux, ["-L", socket, "kill-server"], environment: TmuxRunner.environment(socket: socket), timeout: 5)
            }
            try? FileManager.default.removeItem(atPath: root)
        }

        // The stub copies each stdin line to a file and to stdout (the out log), then runs on.
        let claude = """
        #!/bin/bash
        if [[ "${1-}" == update ]]; then exit 0; fi
        while IFS= read -r line; do echo "$line" >> '\(received)'; echo "$line"; done
        """
        try claude.write(toFile: stub + "/claude", atomically: true, encoding: .utf8)
        for name in ["lean-ctx", "headroom", "repowire", "osascript", "nohup", "pgrep"] {
            try "#!/bin/bash\nexit 0\n".write(toFile: stub + "/" + name, atomically: true, encoding: .utf8)
        }
        let chmod = shell("chmod +x '\(stub)'/*", in: root, env: ["PATH": "/bin:/usr/bin"])
        #expect(chmod.status == 0)

        var toolPath = stub
        for tool in ["tmux", "git", "sqlite3", "perl", "jq", "uuidgen"] {
            if let found = OrchestratorPaths.searchPath.split(separator: ":").map({ "\($0)/\(tool)" })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                let dir = (found as NSString).deletingLastPathComponent
                if !toolPath.split(separator: ":").contains(Substring(dir)) { toolPath += ":" + dir }
            }
        }
        toolPath += ":/usr/bin:/bin"
        let envFile = root + "/app.env"
        try "PATH=\(toolPath)\nTERM=dumb\nCLAUDE_IN_TMUX=0\nHOME=\(home)\n".write(toFile: envFile, atomically: true, encoding: .utf8)

        let env = ["PATH": toolPath, "HOME": home, "LANG": "en_US.UTF-8", "ORCH_TMUX_SOCKET": socket]
        let setup = shell("git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init", in: project, env: env)
        #expect(setup.status == 0)
        let launched = shell("'\(Self.launcher)' --gui-folder '\(project)' --env-file '\(envFile)'", in: project, env: env)
        #expect(launched.status == 0, "\(launched.stderr)")
        let base = try #require(launched.stdout.split(separator: "\n").last.map(String.init))

        let windows = try #require(try ProjectSession.liveWindows(base: base, socket: socket))
        let folder = try #require(windows.first { $0.name == "dashboard" }?.path)
        let inbox = try #require(WorkerDatabase(project: folder).inboxPath(of: "dashboard"))

        let dispatch = "Pick up the Notion task: Fix the thing"
        let review = "merge-review merged alpha"
        #expect(InboxDelivery.deliver(dispatch, base: base, socket: socket) == .sent)
        #expect(InboxDelivery.deliver(review, base: base, socket: socket) == .sent)
        let request = PRMergeRequest(deliver: { InboxDelivery.deliver($0, base: $1, socket: socket) })
        await request.send(number: 7, label: "alpha", title: "Add the export", base: base)
        let prLine = try #require(PRMergeRequest.line(number: 7, label: "alpha", title: "Add the export"))
        #expect(request.state == .sent("Request sent: \(prLine)"))

        let expected = [dispatch, review, prLine]
        // A seed prompt, if the launcher writes one, comes before these lines.
        #expect(wait { lines(received).compactMap(userContent).count >= 3 })
        #expect(Array(lines(received).compactMap(userContent).suffix(3)) == expected)
        #expect(Array(lines(inbox).compactMap(userContent).suffix(3)) == expected)
    }
}
