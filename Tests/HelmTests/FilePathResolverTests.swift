import Foundation
import Testing
@testable import Helm

@Suite struct FilePathResolverTests {
    let top: URL
    let project: URL
    let worktree: URL

    init() throws {
        top = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-\(UUID().uuidString)")
        project = top.appendingPathComponent("proj")
        worktree = project.appendingPathComponent(".claude/worktrees/w1")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: top.appendingPathComponent("proj-evil"), withIntermediateDirectories: true)
    }

    private func touch(_ url: URL) throws { try "x".write(to: url, atomically: true, encoding: .utf8) }
    private func resolve(_ text: String, wt: URL? = nil) -> Result<ResolvedFile, FileRefusal> {
        FilePathResolver.resolve(text, project: project, worktree: wt ?? worktree)
    }
    private func reason(_ r: Result<ResolvedFile, FileRefusal>) -> String? {
        if case .failure(let f) = r { return f.reason }
        return nil
    }

    @Test func worktreeCopyWinsWithNoPerFileFallback() throws {
        try touch(worktree.appendingPathComponent("x.swift"))
        try touch(project.appendingPathComponent("x.swift"))
        try touch(project.appendingPathComponent("only.swift"))
        let hit = try resolve("x.swift").get()
        #expect(hit.root == .worktree)
        #expect(hit.url.path.contains("worktrees/w1/x.swift"))
        #expect(reason(resolve("only.swift")) == "does not exist")
    }

    @Test func lineNumberReadsTheFirstLineOfEverySuffixForm() {
        for text in ["a.swift:12", "a.swift:12-20", "a.swift:12,15", "a.swift:12:3"] {
            #expect(FilePathResolver.lineNumber(in: text) == 12)
        }
        #expect(FilePathResolver.lineNumber(in: "a.swift") == nil)
        #expect(FilePathResolver.lineNumber(in: "odd:name.md") == nil)
    }

    @Test func projectCopyAfterWorktreeIsGone() throws {
        try touch(project.appendingPathComponent("x.swift"))
        try FileManager.default.removeItem(at: worktree)
        let hit = try resolve("x.swift").get()
        #expect(hit.root == .project)
    }

    @Test func absolutePathInNestedWorktreeReportsWorktree() throws {
        let file = worktree.appendingPathComponent("a.md")
        try touch(file)
        #expect(try resolve(file.path).get().root == .worktree)
    }

    @Test func fifoIsNotARegularFile() throws {
        let fifo = worktree.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(reason(resolve("pipe")) == "not a regular file")
    }

    @Test func outsidePathsAreRefused() throws {
        try touch(top.appendingPathComponent("proj-evil/x"))
        let outside = top.appendingPathComponent("outside.txt")
        try touch(outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link.txt"), withDestinationURL: outside)
        let outsideReason = "outside the project and the worktree"
        #expect(reason(resolve("../x", wt: top.appendingPathComponent("none"))) == outsideReason)
        #expect(reason(resolve("/etc/hosts")) == outsideReason)
        #expect(reason(resolve(top.appendingPathComponent("proj-evil/x").path)) == outsideReason)
        #expect(reason(resolve("link.txt", wt: top.appendingPathComponent("none"))) == outsideReason)
    }

    @Test func urlsAndControlCharactersAreRefused() {
        for text in ["file:///etc/hosts", "https://a.b/c", "a.md\nb", "", "mailto:a.md"] {
            #expect(reason(resolve(text)) == "not a plain path", "\(text)")
        }
    }

    @Test func lineReferencesAreStripped() throws {
        try touch(worktree.appendingPathComponent("Sources/a.swift"))
        for text in ["Sources/a.swift:101-109", "Sources/a.swift:172-177,273", "Sources/a.swift:12:5"] {
            #expect(try resolve(text).get().url.lastPathComponent == "a.swift", "\(text)")
        }
    }

    @Test func classifiesTheRealPathNotTheLinkName() throws {
        let app = worktree.appendingPathComponent("Foo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: worktree.appendingPathComponent("a.md"), withDestinationURL: app)
        let facts = try resolve("a.md").get().facts
        #expect(facts.ext == "app" && facts.isDirectory)
        #expect(FileOpenPolicy.decide(facts) != .editor)
    }
}
