import Foundation
import Testing
@testable import Helm

@Suite(.serialized) struct ProjectSessionTests {
    private func dashboard(_ path: String) -> [SessionWindow] { [SessionWindow(name: "dashboard", path: path)] }

    private func newFolder() throws -> String {
        let dir = NSTemporaryDirectory() + "project-session-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func gitEnvironment() throws -> [String: String] {
        let home = try newFolder()
        try "[user]\n\tname = Test\n\temail = test@example.com\n".write(
            toFile: home + "/.gitconfig", atomically: true, encoding: .utf8)
        return ["PATH": OrchestratorPaths.searchPath, "HOME": home, "LANG": "en_US.UTF-8"]
    }

    // MARK: pure check

    @Test func noSessionIsFree() {
        #expect(ProjectSession.classify(windows: nil, expected: "/work/a") == .free)
    }

    @Test func aDashboardInTheSameFolderIsTheSameProject() {
        #expect(ProjectSession.classify(windows: dashboard("/work/a"), expected: "/work/a") == .sameProject)
    }

    @Test func aDashboardReachedThroughASymlinkIsTheSameProject() throws {
        let real = try newFolder()
        let link = try newFolder() + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(ProjectSession.classify(windows: dashboard(link), expected: real) == .sameProject)
        #expect(ProjectSession.classify(windows: dashboard(real), expected: link) == .sameProject)
    }

    @Test func aDashboardInAnotherFolderIsInUse() {
        #expect(ProjectSession.classify(windows: dashboard("/work/b"), expected: "/work/a") == .inUse("/work/b"))
    }

    @Test func aSessionWithoutADashboardWindowIsInUse() {
        let windows = [SessionWindow(name: "main", path: "/work/a")]
        #expect(ProjectSession.classify(windows: windows, expected: "/work/a") == .inUse("a session with no dashboard window"))
    }

    @Test func windowsAreParsedFromTabSeparatedLines() {
        #expect(ProjectSession.parseWindows("dashboard\t/work/a\nw1\t/work/a b\n")
            == [SessionWindow(name: "dashboard", path: "/work/a"), SessionWindow(name: "w1", path: "/work/a b")])
    }

    // MARK: expected folder

    @Test func theExpectedFolderOfARepoIsItself() throws {
        let env = try gitEnvironment()
        let dir = try newFolder()
        try FolderCheck.initRepo(dir, environment: env)
        #expect(ProjectSession.expectedFolder(dir) == FolderCheck.realPath(dir))
    }

    @Test func theExpectedFolderOfALinkedWorktreeIsItsMainRepository() throws {
        let env = try gitEnvironment()
        let main = try newFolder()
        try FolderCheck.initRepo(main, environment: env)
        let worktree = try newFolder() + "-wt"
        #expect(FolderCheck.runGit(["-C", main, "worktree", "add", worktree], environment: env).status == 0)
        #expect(ProjectSession.expectedFolder(worktree) == FolderCheck.realPath(main))
    }

    @Test func theExpectedFolderOfAPlainFolderIsItself() throws {
        let dir = try newFolder()
        #expect(ProjectSession.expectedFolder(dir) == FolderCheck.realPath(dir))
    }

    // MARK: live query on a private tmux server

    private func tmux(_ socket: String, _ args: [String]) -> ProcessResult {
        guard let path = OrchestratorPaths.tmuxPath() else { return ProcessResult(status: -1, stdout: "", stderr: "") }
        return ProcessRunner.run(path, ["-L", socket] + args, environment: TmuxRunner.environment(), timeout: 5)
    }

    @Test func aSessionNamedOnlyAsAPrefixOfTheWantedNameIsFree() throws {
        let socket = "gui-test-\(UUID().uuidString.prefix(8).lowercased())"
        defer { _ = tmux(socket, ["kill-server"]) }
        let dir = try newFolder()
        _ = tmux(socket, ["new-session", "-d", "-s", "proj-longer", "-n", "dashboard", "-c", dir, "sleep 600"])
        #expect(try ProjectSession.liveWindows(base: "proj", socket: socket) == nil)
        let found = try #require(try ProjectSession.liveWindows(base: "proj-longer", socket: socket))
        #expect(found.first?.name == "dashboard")
        #expect(FolderCheck.realPath(found.first?.path ?? "") == FolderCheck.realPath(dir))
        #expect(try ProjectSession.claim(base: "proj-longer", folder: dir, socket: socket) == .sameProject)
    }

    @Test func noServerAtAllIsFree() throws {
        #expect(try ProjectSession.liveWindows(base: "proj", socket: "gui-test-none-\(UUID().uuidString.prefix(8).lowercased())") == nil)
    }

    // MARK: name derivation against the real library

    private let libraryExists = FileManager.default.fileExists(atPath: OrchestratorPaths.orchestratorRepo + "/orchestration/lib/tmux-session.sh")

    @Test func theNameIsTheOrchestratorsSlug() throws {
        try #require(libraryExists)
        let parent = try newFolder()
        let dir = parent + "/My Proj_X"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #expect(try ProjectSession.baseName(for: dir) == "my-proj-x")
    }

    @Test func aLinkedWorktreeGetsTheMainRepositoryName() throws {
        try #require(libraryExists)
        let env = try gitEnvironment()
        let main = (try newFolder()) + "/Main Repo"
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        try FolderCheck.initRepo(main, environment: env)
        let worktree = try newFolder() + "/other-name"
        #expect(FolderCheck.runGit(["-C", main, "worktree", "add", worktree], environment: env).status == 0)
        #expect(try ProjectSession.baseName(for: worktree) == "main-repo")
    }

    @Test func aMissingLibraryFailsWithAReason() {
        #expect(throws: SessionCheckFailure.self) {
            try ProjectSession.baseName(for: "/tmp", library: "/nonexistent/tmux-session.sh")
        }
    }
}
