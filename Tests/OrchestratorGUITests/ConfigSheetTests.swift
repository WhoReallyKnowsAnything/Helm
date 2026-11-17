import Foundation
import Testing
@testable import OrchestratorGUI

/// D-01: temp copies of the fixture only.
struct ConfigSheetTests {
    @Test func readingTheFixtureGivesSonnetAutoTrueFalse() throws {
        let json = try #require(SettingsFileWriterTests.json(SettingsFileWriterTests.fixture.path))
        #expect(ConfigKeys.model(json) == "sonnet")
        #expect(ConfigKeys.defaultMode(json) == "auto")
        #expect(ConfigKeys.autoCompact(json) == true)
        #expect(ConfigKeys.coAuthoredBy(json) == false)
        #expect(ConfigKeys.model(["model": "claude-x"]) == nil)
        #expect(ConfigKeys.model(["model": "opus"]) == "opus")
    }

    @Test func eachControlChangesOnlyItsValue() throws {
        let cases: [(path: [String], old: String, new: String)] = [
            (ConfigKeys.autoCompact, "true", ConfigKeys.text(false)),
            (ConfigKeys.model, "\"sonnet[1m]\"", ConfigKeys.text(model: "haiku")),
            (ConfigKeys.defaultMode, "\"auto\"", ConfigKeys.text(mode: "plan")),
            (ConfigKeys.coAuthoredBy, "false", ConfigKeys.text(true)),
        ]
        let original = try #require(SettingsFileWriterTests.json(SettingsFileWriterTests.fixture.path))
        for item in cases {
            let file = try SettingsFileWriterTests.tempCopy()
            let before = SettingsFileWriterTests.bytes(file)
            let old = "\"\(item.path.last!)\": " + item.old
            #expect(SettingsFileWriter.set(item.path, to: item.new, in: file) == nil)
            let after = SettingsFileWriterTests.bytes(file)
            #expect(SettingsFileWriterTests.onlyOneSpanChanged(before, after, from: old, to: "\"\(item.path.last!)\": " + item.new), "\(item.path)")
            #expect(SettingsFileWriterTests.mode(file) == 0o600)
            let json = try #require(SettingsFileWriterTests.json(file))
            let others = cases.map(\.path).filter { $0 != item.path }
            for path in others {
                #expect(value(json, path) as? NSObject == value(original, path) as? NSObject, "\(path)")
            }
        }
        #expect(ConfigKeys.text(model: "opus") == "\"opus[1m]\"")
    }

    private func value(_ json: [String: Any], _ path: [String]) -> Any? {
        path.count == 1 ? json[path[0]] : (json[path[0]] as? [String: Any])?[path[1]]
    }

    @MainActor @Test func theSheetDrawsWithAutoAndWithBypass() throws {
        for mode in ["auto", "bypassPermissions"] {
            let file = try SettingsFileWriterTests.tempCopy(name: "settings.json")
            let home = (file as NSString).deletingLastPathComponent + "/home"
            try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: file, toPath: home + "/.claude/settings.json")
            #expect(SettingsFileWriter.set(ConfigKeys.defaultMode, to: ConfigKeys.text(mode: mode), in: home + "/.claude/settings.json") == nil)
            let sheet = ConfigSheet(home: home, failure: .constant(nil))
            #expect(RenderSupport.distinctColours(try RenderSupport.render(sheet, .content(width: SheetWidth.medium))) > 1, "\(mode)")
        }
    }
}
