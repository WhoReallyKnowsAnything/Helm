import Foundation
import Testing
@testable import OrchestratorGUI

private final class Recorder: WorkspaceOpening, @unchecked Sendable {
    var plainOpens = 0
    var appOpens = 0
    func applicationURL(bundleIdentifier: String) -> URL? { URL(fileURLWithPath: "/Applications/Visual Studio Code.app") }
    func plainTextEditorURL() -> URL? { nil }
    func open(_ file: URL) { plainOpens += 1 }
    func open(_ file: URL, withApplicationAt app: URL) { appOpens += 1 }
}

@Suite struct FileLinkViewTests {
    let project: URL
    let worktree: URL

    init() throws {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        project = top.appendingPathComponent("proj")
        worktree = project.appendingPathComponent(".claude/worktrees/w1")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    }

    private func touch(_ url: URL) throws { try "x".write(to: url, atomically: true, encoding: .utf8) }
    private func link(_ text: String, wt: URL?, canLink: (String) -> Bool = { _ in true }) -> URL? {
        FileLinkView.linkURL(text, project: project, worktree: wt, canLink: canLink)
    }
    private func click(_ url: URL, wt: URL?, _ ws: Recorder = Recorder()) -> FileOpenOutcome? {
        FileLinkView.handle(url, project: project, worktree: wt, workspace: ws)
    }

    @Test func worktreeRuleDecidesTheLink() throws {
        try touch(worktree.appendingPathComponent("Sources/a.swift"))
        try touch(project.appendingPathComponent("Sources/only.swift"))
        let url = try #require(link("Sources/a.swift", wt: worktree))
        #expect(click(url, wt: worktree) == .opened(root: .worktree, app: "Visual Studio Code"))
        #expect(link("Sources/only.swift", wt: worktree) == nil)

        try FileManager.default.removeItem(at: worktree)
        let projectURL = try #require(link("Sources/only.swift", wt: worktree))
        #expect(click(projectURL, wt: worktree) == .opened(root: .project, app: "Visual Studio Code"))
    }

    @Test func appFolderLinksButClickIsRefused() throws {
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("Foo.app"), withIntermediateDirectories: true)
        let ws = Recorder()
        let url = try #require(link("Foo.app", wt: worktree))
        guard case .refused(let reason)? = click(url, wt: worktree, ws) else { Issue.record("opened"); return }
        #expect(!reason.isEmpty)
        #expect(ws.plainOpens + ws.appOpens == 0)
    }

    @Test func missingAndRejectedStayPlain() throws {
        try touch(worktree.appendingPathComponent("a.md"))
        #expect(link("missing.md", wt: worktree) == nil)
        #expect(link("a.md", wt: worktree, canLink: { _ in false }) == nil)
        #expect(link("a.md", wt: worktree) != nil)
    }

    @Test func candidateSurvivesTheUrlRoundTrip() throws {
        try touch(worktree.appendingPathComponent("Sources/a.swift"))
        for text in ["Sources/a.swift:172-177,273", "odd:name,1.md"] {
            let encoded = try #require(FileLinkView.encode(text))
            #expect(FileLinkView.candidate(from: encoded) == text)
        }
        let url = try #require(FileLinkView.linkURL("Sources/a.swift:172-177,273", project: project, worktree: worktree))
        #expect(FileLinkView.candidate(from: url) == "Sources/a.swift:172-177,273")
        let ws = Recorder()
        _ = click(url, wt: worktree, ws)
        #expect(ws.appOpens == 1 && ws.plainOpens == 0)
    }

    @Test func editorActionTakesCodeLinksOnClickAndOnTheAccessibilityRoute() throws {
        try touch(project.appendingPathComponent("Sources/a.swift"))
        try touch(project.appendingPathComponent("pic.png"))
        let real = try FilePathResolver.resolve("Sources/a.swift", project: project, worktree: nil).get().url
        let url = try #require(link("Sources/a.swift:12", wt: nil))
        for viaClick in [true, false] {
            var calls: [(URL, Int?)] = []
            let ws = Recorder()
            let editor: OpenInEditor = { calls.append(($0, $1)) }
            let outcome = viaClick
                ? FileLinkView.handle(url, project: project, worktree: nil, workspace: ws, editor: editor)
                : FileLinkView.route("Sources/a.swift:12", project: project, worktree: nil, workspace: ws, editor: editor)
            #expect(outcome == nil)
            #expect(calls.count == 1 && calls[0].0 == real && calls[0].1 == 12)
            #expect(ws.appOpens == 0 && ws.plainOpens == 0)
        }
    }

    @Test func editorActionIgnoresImagesAndRefusedLinksAndNoActionKeepsVSCode() throws {
        try touch(project.appendingPathComponent("Sources/a.swift"))
        try touch(project.appendingPathComponent("pic.png"))
        var calls = 0
        let editor: OpenInEditor = { _, _ in calls += 1 }

        let png = Recorder()
        _ = FileLinkView.route("pic.png", project: project, worktree: nil, workspace: png, editor: editor)
        #expect(png.plainOpens == 1 && png.appOpens == 0)

        for refused in ["Sources", "/etc/hosts"] {
            let ws = Recorder()
            guard case .refused = FileLinkView.route(refused, project: project, worktree: nil, workspace: ws, editor: editor) else {
                Issue.record("\(refused) was not refused")
                continue
            }
            #expect(ws.plainOpens == 0 && ws.appOpens == 0)
        }
        #expect(calls == 0)

        let vs = Recorder()
        _ = FileLinkView.route("Sources/a.swift:12", project: project, worktree: nil, workspace: vs, editor: nil)
        #expect(vs.appOpens == 1 && vs.plainOpens == 0)
    }

    @Test func everyLinkIsAnAccessibleButtonNamingItsFile() throws {
        try touch(worktree.appendingPathComponent("Sources/a.swift"))
        let links = FileLinkView.accessibleLinks(
            "See Sources/a.swift and missing.md", project: project, worktree: worktree, canLink: { _ in true })
        #expect(links.map(\.candidate) == ["Sources/a.swift"])
        #expect(links.map(\.label) == ["Open Sources/a.swift"])
        #expect(FileLinkView.accessibleLinks("a.md", project: project, worktree: worktree, canLink: { _ in false }).isEmpty)
    }
}
