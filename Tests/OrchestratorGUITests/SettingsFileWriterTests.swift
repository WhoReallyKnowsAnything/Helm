import Foundation
import Testing
@testable import OrchestratorGUI

/// D-01: every test writes temp copies only. Never the real settings files.
struct SettingsFileWriterTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/settings-user.json")

    /// A 0600 temp copy of the fixture (or of `text`) in a fresh temp folder.
    static func tempCopy(_ text: String? = nil, name: String = "settings.json") throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sfw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name).path
        let data = try text.map { Data($0.utf8) } ?? Data(contentsOf: fixture)
        #expect(FileManager.default.createFile(atPath: file, contents: data, attributes: [.posixPermissions: 0o600]))
        return file
    }

    static func bytes(_ file: String) -> [UInt8] { [UInt8](FileManager.default.contents(atPath: file) ?? Data()) }
    static func mode(_ file: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: file))?[.posixPermissions] as? Int }
    static func json(_ file: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(bytes(file)))) as? [String: Any]
    }

    /// True when `new` is `old` with only the bytes of one range swapped: same prefix and suffix around it.
    static func onlyOneSpanChanged(_ old: [UInt8], _ new: [UInt8], from: String, to: String) -> Bool {
        guard let range = old.indices.first(where: { old[$0...].starts(with: Array(from.utf8)) }) else { return false }
        let end = range + from.utf8.count
        return Array(new.prefix(range)) == Array(old.prefix(range))
            && Array(new.suffix(old.count - end)) == Array(old[end...])
            && new.count == old.count - from.utf8.count + to.utf8.count
    }

    @Test func replacingTheTopLevelModelChangesOnlyItsValue() throws {
        let file = try Self.tempCopy()
        let before = Self.bytes(file)
        #expect(SettingsFileWriter.set(["model"], to: "\"haiku\"", in: file) == nil)
        let after = Self.bytes(file)
        #expect(Self.onlyOneSpanChanged(before, after, from: "\"sonnet[1m]\"", to: "\"haiku\""))
        let parsed = try #require(Self.json(file))
        #expect(parsed["model"] as? String == "haiku")
        #expect((parsed["agentDefaults"] as? [String: Any])?["model"] as? String == "haiku")
        #expect(String(decoding: after, as: UTF8.self).contains(#""command": "echo \"model\": \"opus\" > /dev/null""#))
        #expect(Self.mode(file) == 0o600)
    }

    @Test func aFileThatIsNotJSONIsRefusedAndStaysTheSame() throws {
        let file = try Self.tempCopy("{\"model\": \"opus\",")
        let before = Self.bytes(file)
        #expect(SettingsFileWriter.set(["model"], to: "\"haiku\"", in: file) != nil)
        #expect(Self.bytes(file) == before)
    }

    @Test func aSymlinkStaysASymlinkAfterAWrite() throws {
        let file = try Self.tempCopy()
        let link = (file as NSString).deletingLastPathComponent + "/link.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
        #expect(SettingsFileWriter.set(["permissions", "defaultMode"], to: "\"plan\"", in: link) == nil)
        #expect((try FileManager.default.attributesOfItem(atPath: link))[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect((Self.json(file)?["permissions"] as? [String: Any])?["defaultMode"] as? String == "plan")
    }

    /// True when `new` is `old` with only `added` inserted at 1 place.
    static func onlyInserted(_ old: [UInt8], _ new: [UInt8], _ added: String) -> Bool {
        let count = new.count - old.count
        guard count == added.utf8.count else { return false }
        let at = zip(old, new).prefix { $0 == $1 }.count
        return Array(new[at..<at + count]) == Array(added.utf8) && Array(new[(at + count)...]) == Array(old[at...])
    }

    @Test func insertingAMissingListIntoAOneLineFileAddsOnlyThatText() throws {
        let file = try Self.tempCopy(#"{"permissions":{"allow":["mcp__lean-ctx__ctx_shell"]}}"#)
        let before = Self.bytes(file)
        #expect(SettingsFileWriter.set(["permissions", "ask"], to: #"["Bash(git push:*)"]"#, in: file) == nil)
        #expect(Self.onlyInserted(before, Self.bytes(file), #","ask":["Bash(git push:*)"]"#))
        #expect((Self.json(file)?["permissions"] as? [String: Any])?["ask"] as? [String] == ["Bash(git push:*)"])
    }

    @Test func insertingIntoTheIndentedFixtureUsesTheSiblingIndent() throws {
        let file = try Self.tempCopy()
        let before = Self.bytes(file)
        #expect(SettingsFileWriter.set(["verbose"], to: "true", in: file) == nil)
        #expect(Self.onlyInserted(before, Self.bytes(file), ",\n  \"verbose\": true"))
    }

    @Test func aMissingFileIsCreatedWithOnlyPermissionsAndMode0600() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sfw-\(UUID().uuidString)")
        let file = home.appendingPathComponent(".claude/settings.local.json").path
        #expect(SettingsFileWriter.set(["permissions", "allow"], to: #"["Read(/tmp/**)"]"#, in: file) == nil)
        #expect(String(decoding: Self.bytes(file), as: UTF8.self) == #"{"permissions":{"allow":["Read(/tmp/**)"]}}"#)
        #expect(Self.mode(file) == 0o600)
        #expect(Self.json(file)?.keys.sorted() == ["permissions"])
    }

    @Test func addThenRemoveARuleGivesBackTheOriginalBytes() throws {
        let file = try Self.tempCopy()
        let before = Self.bytes(file)
        let text = String(decoding: before, as: UTF8.self)
        let open = try #require(text.range(of: "\"allow\": [")).upperBound
        let close = try #require(text.range(of: "]", range: open..<text.endIndex)).lowerBound
        let head = text[..<open].utf8.count - 1, tail = text[close...].utf8.count
        #expect(SettingsFileWriter.addRule("Bash(echo phase7:*)", to: "allow", in: file) == nil)
        let after = Self.bytes(file)
        #expect(Array(after.prefix(head + 1)) == Array(before.prefix(head + 1)))
        #expect(Array(after.suffix(tail)) == Array(before.suffix(tail)))
        #expect((Self.json(file)?["permissions"] as? [String: Any])?["allow"] as? [String]
                == ["Bash(git status:*)", "Read(/tmp/**)", "Bash(echo phase7:*)"])
        #expect(Self.mode(file) == 0o600)
        #expect(SettingsFileWriter.removeRule("Bash(echo phase7:*)", from: "allow", in: file) == nil)
        #expect(Self.bytes(file) == before)
    }

    @Test func removingTheFirstOrOnlyRuleAndAddingToAnEmptyListKeepTheRest() throws {
        let file = try Self.tempCopy()
        let before = Self.bytes(file)
        #expect(SettingsFileWriter.removeRule("Bash(git status:*)", from: "allow", in: file) == nil)
        #expect((Self.json(file)?["permissions"] as? [String: Any])?["allow"] as? [String] == ["Read(/tmp/**)"])
        #expect(SettingsFileWriter.removeRule("Read(./.env)", from: "deny", in: file) == nil)
        #expect((Self.json(file)?["permissions"] as? [String: Any])?["deny"] as? [String] == [])
        #expect(SettingsFileWriter.addRule("Read(./.env)", to: "deny", in: file) == nil)
        #expect((Self.json(file)?["permissions"] as? [String: Any])?["deny"] as? [String] == ["Read(./.env)"])
        #expect(Self.bytes(file).count < before.count)
    }

    @Test func badRulesAreRefusedAndLeaveTheFileTheSame() throws {
        let file = try Self.tempCopy()
        let before = Self.bytes(file)
        #expect(SettingsFileWriter.addRule("  ", to: "allow", in: file) != nil)
        #expect(SettingsFileWriter.addRule("Bash(git status:*)", to: "allow", in: file) != nil)
        #expect(SettingsFileWriter.addRule("Bash(a\u{7}b)", to: "allow", in: file) != nil)
        #expect(SettingsFileWriter.removeRule("Bash(nope)", from: "ask", in: file) != nil)
        #expect(Self.bytes(file) == before)
    }
}
