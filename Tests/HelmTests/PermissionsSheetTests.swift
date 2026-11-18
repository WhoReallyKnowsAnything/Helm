import Foundation
import Testing
@testable import Helm

struct PermissionsSheetTests {
    static func tempFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func aProjectCwdGivesLocalProjectAndUser() throws {
        let home = try Self.tempFolder(), cwd = try Self.tempFolder()
        let scopes = PermissionScope.scopes(cwd: cwd, home: home)
        #expect(scopes.map(\.name) == ["Local", "Project", "User"])
        #expect(scopes.map(\.path) == [cwd + "/.claude/settings.local.json", cwd + "/.claude/settings.json", home + "/.claude/settings.json"])
    }

    @Test func theHomeFolderAndAnEmptyCwdGiveOnlyUser() throws {
        let home = try Self.tempFolder()
        let link = try Self.tempFolder() + "/home-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home)
        for cwd in [home, link, ""] {
            #expect(PermissionScope.scopes(cwd: cwd, home: home).map(\.path) == [home + "/.claude/settings.json"])
        }
    }

    @MainActor @Test func theSheetDrawsOverASettingsFileAndOverAMissingFile() throws {
        let home = try Self.tempFolder(), cwd = try Self.tempFolder()
        let missing = PermissionsSheet(cwd: cwd, home: home, failure: .constant(nil))
        #expect(RenderSupport.distinctColours(try RenderSupport.render(missing, .content(width: SheetWidth.medium))) > 1)
        try FileManager.default.createDirectory(atPath: cwd + "/.claude", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: SettingsFileWriterTests.fixture.path, toPath: cwd + "/.claude/settings.local.json")
        let sheet = PermissionsSheet(cwd: cwd, home: home, failure: .constant(nil))
        #expect(SettingsRead(path: cwd + "/.claude/settings.local.json").rules("allow") == ["Bash(git status:*)", "Read(/tmp/**)"])
        #expect(RenderSupport.distinctColours(try RenderSupport.render(sheet, .content(width: SheetWidth.medium))) > 1)
    }
}
