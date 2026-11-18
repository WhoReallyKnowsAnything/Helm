import Foundation
import Testing
@testable import Helm

private final class Recorder: WorkspaceOpening, @unchecked Sendable {
    var vsCode: URL? = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
    var plainText: URL? = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    var plainOpens: [URL] = []
    var appOpens: [(file: URL, app: URL)] = []
    var calls: Int { plainOpens.count + appOpens.count }
    func applicationURL(bundleIdentifier: String) -> URL? { bundleIdentifier == "com.microsoft.VSCode" ? vsCode : nil }
    func plainTextEditorURL() -> URL? { plainText }
    func open(_ file: URL) { plainOpens.append(file) }
    func open(_ file: URL, withApplicationAt app: URL) { appOpens.append((file, app)) }
}

@Suite struct FileOpenerTests {
    let project: URL

    init() throws {
        project = FileManager.default.temporaryDirectory.appendingPathComponent("opener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    private func make(_ name: String, exec: Bool = false) throws {
        let url = project.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        if exec { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    private func open(_ text: String, _ ws: Recorder) -> FileOpenOutcome {
        FileOpener.open(text, project: project, worktree: nil, workspace: ws)
    }

    @Test func codeFilesAlwaysCarryTheVSCodeUrl() throws {
        try make("a.sh", exec: true); try make("b.command", exec: true); try make("c.swift")
        let ws = Recorder()
        for name in ["a.sh", "b.command", "c.swift"] {
            #expect(open(name, ws) == .opened(root: .project, app: "Visual Studio Code"))
        }
        #expect(ws.plainOpens.isEmpty)
        #expect(ws.appOpens.count == 3)
        #expect(ws.appOpens.allSatisfy { $0.app == ws.vsCode })
    }

    @Test func withoutVSCodeUsesThePlainTextEditor() throws {
        try make("c.swift")
        let ws = Recorder(); ws.vsCode = nil
        _ = open("c.swift", ws)
        #expect(ws.appOpens.map(\.app) == [ws.plainText!])
        #expect(ws.plainOpens.isEmpty)
    }

    @Test func noEditorAtAllIsRefused() throws {
        try make("c.swift")
        let ws = Recorder(); ws.vsCode = nil; ws.plainText = nil
        #expect(open("c.swift", ws) == .refused("no editor found"))
        #expect(ws.calls == 0)
    }

    @Test func pngUsesThePlainOpen() throws {
        try make("p.png")
        let ws = Recorder()
        #expect(open("p.png", ws) == .opened(root: .project, app: "default app"))
        #expect(ws.plainOpens.count == 1 && ws.appOpens.isEmpty)
    }

    @Test func refusedCasesCallNothing() throws {
        try make("x.png", exec: true); try make("l.webloc"); try make("noext", exec: true); try make("n.svg")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Foo.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("dir"), withIntermediateDirectories: true)
        let ws = Recorder()
        for text in ["x.png", "l.webloc", "noext", "n.svg", "Foo.app", "dir", "../x", "/etc/hosts", "file:///etc/hosts", "missing.swift"] {
            guard case .refused(let reason) = open(text, ws) else { Issue.record("\(text) opened"); continue }
            #expect(!reason.isEmpty)
        }
        #expect(open("n.svg", ws) == .refused("type not on open list"))
        #expect(ws.calls == 0)
    }
}
