import Foundation
import Testing
@testable import Helm

struct ProjectLauncherTests {
    private let secret = "SECRET-MARKER-9f3a"

    /// A stub launcher that records what it was given, then runs `tail`.
    private func stub(tail: String) throws -> (launcher: String, rec: String) {
        let rec = NSTemporaryDirectory() + "launcher-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: rec, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(rec)/argv
        env > \(rec)/env
        envf=; prev=
        for a in "$@"; do [ "$prev" = --env-file ] && envf=$a; prev=$a; done
        cp "$envf" \(rec)/envcopy
        stat -f %Lp "$envf" > \(rec)/filemode
        stat -f %Lp "$(dirname "$envf")" > \(rec)/dirmode
        echo "$envf" > \(rec)/path
        \(tail)
        """
        let path = rec + "/launcher"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, rec)
    }

    private func read(_ rec: String, _ name: String) -> String {
        (try? String(contentsOfFile: rec + "/" + name, encoding: .utf8)) ?? ""
    }

    private func folder() throws -> String {
        let dir = NSTemporaryDirectory() + "launcher-folder-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func passesOnlyPathsAndKeepsTheSecretInThePrivateFile() throws {
        let (launcher, rec) = try stub(tail: "echo noise; echo my-session; exit 0")
        let dir = try folder()
        let result = try ProjectLauncher.launch(folder: dir, envText: "PATH=/bin\nANTHROPIC_API_KEY=\(secret)\n", launcher: launcher)
        let path = read(rec, "path").trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(read(rec, "argv") == "--gui-folder\n\(dir)\n--env-file\n\(path)\n")
        #expect(read(rec, "envcopy").contains(secret))
        #expect(!read(rec, "argv").contains(secret))
        #expect(!read(rec, "env").contains(secret))
        #expect(read(rec, "filemode").trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        #expect(read(rec, "dirmode").trimmingCharacters(in: .whitespacesAndNewlines) == "700")
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
        #expect(result == LaunchResult(base: "my-session", reused: false, output: "noise\nmy-session"))
    }

    @Test func rootModePassesGuiRootAndTheEnvFileOnly() throws {
        let (launcher, rec) = try stub(tail: "echo root-session; exit 3")
        let result = try ProjectLauncher.launchRoot(envText: "PATH=/bin\n", launcher: launcher)
        let argv = read(rec, "argv").split(separator: "\n").map(String.init)

        #expect(argv.count == 3 && argv[0] == "--gui-root" && argv[1] == "--env-file" && argv[2].hasPrefix(NSTemporaryDirectory()))
        #expect(!argv.contains("--gui-folder"))
        #expect(result.base == "root-session" && result.reused)
    }

    @Test func theStubSeesOnlyPathHomeAndLang() throws {
        let (launcher, rec) = try stub(tail: "echo s")
        _ = try ProjectLauncher.launch(folder: try folder(), envText: "PATH=/bin\n", launcher: launcher)
        let shellAdded: Set<String> = ["PWD", "SHLVL", "_", "OLDPWD"]
        let names = Set(read(rec, "env").split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        #expect(names.subtracting(shellAdded) == ["PATH", "HOME", "LANG"])
    }

    @Test func exitThreeMeansReused() throws {
        let (launcher, _) = try stub(tail: "echo again; exit 3")
        #expect(try ProjectLauncher.launch(folder: try folder(), envText: "PATH=/bin\n", launcher: launcher).reused)
    }

    @Test func aResumeIdGoesBeforeTheEnvFile() throws {
        let id = "00000000-0000-0000-0000-000000000001"
        let (rootLauncher, rootRec) = try stub(tail: "echo root; exit 0")
        _ = try ProjectLauncher.launchRoot(envText: "PATH=/bin\n", resumeId: id, launcher: rootLauncher)
        let argv = read(rootRec, "argv").split(separator: "\n").map(String.init)
        #expect(argv.count == 5 && Array(argv.prefix(4)) == ["--gui-root", "--resume", id, "--env-file"])

        let (launcher, rec) = try stub(tail: "echo s; exit 0")
        let dir = try folder()
        _ = try ProjectLauncher.launch(folder: dir, envText: "PATH=/bin\n", resumeId: id, launcher: launcher)
        #expect(read(rec, "argv").hasPrefix("--gui-folder\n\(dir)\n--resume\n\(id)\n--env-file\n"))
    }

    @Test func exitThreeWithAResumeIdIsAFailure() throws {
        let (launcher, _) = try stub(tail: "echo again; exit 3")
        #expect(throws: LaunchFailure.self) {
            try ProjectLauncher.launch(folder: try folder(), envText: "PATH=/bin\n", resumeId: "x", launcher: launcher)
        }
        #expect(try ProjectLauncher.launchRoot(envText: "PATH=/bin\n", launcher: launcher).reused)
    }

    @Test func exitOneIsAFailureWithStderrAndCleansUp() throws {
        let (launcher, rec) = try stub(tail: "echo 'no good' >&2; exit 1")
        #expect(throws: LaunchFailure(reason: "no good")) {
            try ProjectLauncher.launch(folder: try folder(), envText: "PATH=/bin\n", launcher: launcher)
        }
        let path = read(rec, "path").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }

    @Test func aSlowLauncherIsAFailure() throws {
        let (launcher, rec) = try stub(tail: "sleep 30")
        let start = Date()
        #expect(throws: LaunchFailure.self) {
            try ProjectLauncher.launch(folder: try folder(), envText: "PATH=/bin\n", launcher: launcher, timeout: 1)
        }
        #expect(Date().timeIntervalSince(start) < 5)
        let path = read(rec, "path").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }

    @Test func aMissingLauncherIsAFailure() throws {
        #expect(throws: LaunchFailure.self) {
            try ProjectLauncher.launch(folder: try folder(), envText: "PATH=/bin\n", launcher: "/nonexistent/launch-claude.sh")
        }
    }

    @Test func successWithNoSessionNameIsAFailure() throws {
        let (launcher, _) = try stub(tail: "exit 0")
        #expect(throws: LaunchFailure.self) {
            try ProjectLauncher.launch(folder: try folder(), envText: "PATH=/bin\n", launcher: launcher)
        }
    }

    // `--gui-new`. Every call below passes a stub as `launcher:`, so no test can reach the real script.
    private let created = "echo folder=/p/alpha; echo repo=none; echo alpha-session"

    @Test(arguments: GithubChoice.allCases) func guiNewPassesTheNameTheChoiceAndOnlyTheEnvFile(choice: GithubChoice) throws {
        let (launcher, rec) = try stub(tail: created)
        _ = try ProjectLauncher.newProject(name: "alpha", github: choice, envText: "PATH=/bin\nK=\(secret)\n", launcher: launcher)
        let path = read(rec, "path").trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(read(rec, "argv") == "--gui-new\nalpha\n--github\n\(choice.rawValue)\n--env-file\n\(path)\n")
        #expect(path.hasPrefix(NSTemporaryDirectory()))
        #expect(read(rec, "envcopy").contains(secret))
        #expect(!read(rec, "argv").contains(secret))
        #expect(!read(rec, "env").contains(secret))
        #expect(read(rec, "filemode").trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        #expect(read(rec, "dirmode").trimmingCharacters(in: .whitespacesAndNewlines) == "700")
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }

    @Test func guiNewReadsTheFolderAndTheLastLineFromStdout() throws {
        let (launcher, _) = try stub(tail: created)
        let result = try ProjectLauncher.newProject(name: "alpha", github: .skip, envText: "PATH=/bin\n", launcher: launcher)
        #expect(result.base == "alpha-session" && result.folder == "/p/alpha" && !result.reused && result.warnings.isEmpty)
    }

    @Test func guiNewIgnoresAFolderLineOnStderrAndNeedsOneOnStdout() throws {
        let (launcher, _) = try stub(tail: "echo folder=/evil >&2; echo alpha-session")
        #expect(throws: LaunchFailure.self) {
            try ProjectLauncher.newProject(name: "alpha", github: .skip, envText: "PATH=/bin\n", launcher: launcher)
        }
    }

    @Test func guiNewKeepsWarningLinesVerbatimAndIgnoresOtherStderr() throws {
        let (launcher, _) = try stub(tail: "echo 'warning: github: gh repo create failed' >&2; echo 'noise' >&2; echo 'warning: notion: no row' >&2; \(created)")
        let result = try ProjectLauncher.newProject(name: "alpha", github: .privateRepo, envText: "PATH=/bin\n", launcher: launcher)
        #expect(result.warnings == ["warning: github: gh repo create failed", "warning: notion: no row"])
    }

    @Test func guiNewTimeoutDefaultsTo120AndNamesTheTimeout() throws {
        #expect(ProjectLauncher.createTimeout == 120)
        let (launcher, _) = try stub(tail: "sleep 30")
        let start = Date()
        do {
            _ = try ProjectLauncher.newProject(name: "alpha", github: .skip, envText: "PATH=/bin\n", launcher: launcher, timeout: 1)
            Issue.record("expected a timeout")
        } catch let failure as LaunchFailure {
            #expect(failure.reason.contains("timed out after 1 seconds"))
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test(arguments: [("exit 1", "bad name"), ("exit 5", "git init failed")]) func guiNewShowsStderrOnExit1And5(code: String, text: String) throws {
        let (launcher, rec) = try stub(tail: "echo '\(text)' >&2; \(code)")
        #expect(throws: LaunchFailure(reason: text)) {
            try ProjectLauncher.newProject(name: "alpha", github: .skip, envText: "PATH=/bin\n", launcher: launcher)
        }
        let path = read(rec, "path").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }

    @Test func guiNewExit4IsProjectExistsAndIgnoresStderr() throws {
        let (launcher, rec) = try stub(tail: "echo 'Error: /x already exists' >&2; exit 4")
        do {
            _ = try ProjectLauncher.newProject(name: "alpha", github: .skip, envText: "PATH=/bin\n", launcher: launcher)
            Issue.record("expected ProjectExists")
        } catch let exists as ProjectExists {
            #expect(exists == ProjectExists(name: "alpha"))
            #expect(exists.localizedDescription == "alpha already exists in ~/Documents/Projects.")
        }
        let path = read(rec, "path").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }

    @Test func guiNewExit3IsReusedAndExit0IsNot() throws {
        let (three, _) = try stub(tail: "\(created); exit 3")
        let (zero, _) = try stub(tail: created)
        #expect(try ProjectLauncher.newProject(name: "alpha", github: .skip, envText: "PATH=/bin\n", launcher: three).reused)
        #expect(try !ProjectLauncher.newProject(name: "alpha", github: .skip, envText: "PATH=/bin\n", launcher: zero).reused)
    }

    @Test func exit4StaysAPlainFailureForTheFolderStart() throws {
        let (launcher, _) = try stub(tail: "exit 4")
        #expect(throws: LaunchFailure(reason: "The launcher exited 4.")) {
            try ProjectLauncher.launch(folder: try folder(), envText: "PATH=/bin\n", launcher: launcher)
        }
    }
}
