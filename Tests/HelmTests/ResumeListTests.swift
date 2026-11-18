import Foundation
import Testing
@testable import Helm

struct ResumeListTests {
    private func temp(_ name: String) throws -> String {
        let path = FolderCheck.realPath(NSTemporaryDirectory()) + "/\(name)-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func write(_ text: String, _ path: String, age: TimeInterval) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: path)
    }

    @Test func titlesOrderAndTheCurrentMark() throws {
        let projects = try temp("projects"), cwd = try temp("cwd")
        defer { try? FileManager.default.removeItem(atPath: projects); try? FileManager.default.removeItem(atPath: cwd) }
        let dir = projects + "/" + ResumeList.slug(cwd)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try write("""
            {"type":"ai-title","aiTitle":"first"}
            {"type":"user","message":{"content":"x"}}
            {"type":"last-prompt","lastPrompt":"ignored"}
            {"type":"ai-title","aiTitle":"second"}
            """, dir + "/a.jsonl", age: 30)
        try write(#"{"type":"last-prompt","lastPrompt":"the prompt"}"# + "\n", dir + "/b.jsonl", age: 10)
        try write(#"{"type":"user","message":{"content":"x"}}"# + "\n", dir + "/c.jsonl", age: 20)

        let rows = ResumeList.rows(cwd: cwd, currentId: "c", projects: projects)
        #expect(rows.map(\.id) == ["b", "c", "a"])
        #expect(rows.map(\.title) == ["the prompt", "c", "second"])
        #expect(rows.map(\.isCurrent) == [false, true, false])
    }

    @Test func sixtyFilesGiveFiftyRowsAndAMissingFolderNone() throws {
        let projects = try temp("projects"), cwd = try temp("cwd")
        defer { try? FileManager.default.removeItem(atPath: projects); try? FileManager.default.removeItem(atPath: cwd) }
        #expect(ResumeList.rows(cwd: cwd, currentId: nil, projects: projects).isEmpty)
        let dir = projects + "/" + ResumeList.slug(cwd)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for n in 0..<60 { try write("", dir + "/s\(n).jsonl", age: TimeInterval(n)) }
        let rows = ResumeList.rows(cwd: cwd, currentId: nil, projects: projects)
        #expect(rows.count == 50 && rows.first?.id == "s0" && rows.last?.id == "s49")
    }

    @Test func aSymlinkedCwdGivesTheRealPathSlug() throws {
        let real = try temp("real.dir"), link = NSTemporaryDirectory() + "link-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: real); try? FileManager.default.removeItem(atPath: link) }
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(ResumeList.slug(link) == ResumeList.slug(real))
        #expect(!ResumeList.slug(real).contains(".") && !ResumeList.slug(real).contains("/"))
    }
}
