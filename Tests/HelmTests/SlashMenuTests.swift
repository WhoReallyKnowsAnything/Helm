import Foundation
import Testing
@testable import Helm

struct SlashMenuTests {
    /// The init event recorded in the fixtures.
    private func recorded() throws -> (commands: [String], skills: [String]) {
        let line = try #require(try ConversationFixtures.lines("text-turn").first { $0.contains(#""subtype":"init""#) })
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return (object["slash_commands"] as? [String] ?? [], object["skills"] as? [String] ?? [])
    }

    @Test func aBareSlashListsTheAllowedBuiltInsSkillsAndPluginCommands() throws {
        let init_ = try recorded()
        let names = SlashMenu.entries(slashCommands: init_.commands, skills: init_.skills, text: "/")
        for name in ["config", "mcp", "permissions", "resume", "context", "model", "effort", "compact", "review",
                     "superpowers:brainstorm", "deploy-check"] {
            #expect(names.contains(name))
        }
        for name in ["agents", "clear"] { #expect(!names.contains(name)) }
    }

    @Test func aPrefixFiltersAndKeepsConfig() throws {
        let init_ = try recorded()
        let names = SlashMenu.entries(slashCommands: init_.commands, skills: init_.skills, text: "/con")
        #expect(names == ["config", "context"])
    }

    @Test func prefixMatchesComeBeforeContainsMatches() {
        let names = SlashMenu.entries(slashCommands: ["a:ctx", "context", "compact"], skills: [], text: "/ctx")
        #expect(names == ["a:ctx"])
        #expect(SlashMenu.allowedBuiltIns == ["context", "model", "effort", "compact"])
        #expect(SlashMenu.entries(slashCommands: ["a:con", "context"], skills: [], text: "/con") == ["config", "context", "a:con"])
    }

    @Test func plainTextAndTextWithASpaceOpenNoMenu() throws {
        let init_ = try recorded()
        #expect(SlashMenu.entries(slashCommands: init_.commands, skills: init_.skills, text: "hello").isEmpty)
        #expect(SlashMenu.entries(slashCommands: init_.commands, skills: init_.skills, text: "/context run").isEmpty)
    }

    @Test func anEmptyInitGivesOnlyTheNativeCommands() {
        #expect(SlashMenu.entries(slashCommands: [], skills: [], text: "/") == ["config", "login", "logout", "mcp", "permissions", "resume", "status"])
    }

    @Test func theListIsCappedAt50() {
        let many = (0..<221).map { "plugin:cmd\($0)" }
        #expect(SlashMenu.entries(slashCommands: many, skills: [], text: "/").count == 50)
    }

    @Test func pickingReplacesWhatWasTyped() {
        #expect(SlashMenu.pick("context") == "/context ")
    }

    @Test func theFourNativeCommandsOpenTheirSheet() {
        #expect(SlashMenu.action(for: "/mcp") == .native(.mcp))
        #expect(SlashMenu.action(for: "/mcp ") == .native(.mcp))
        #expect(SlashMenu.action(for: "/MCP") == .native(.mcp))
        #expect(SlashMenu.action(for: "/permissions") == .native(.permissions))
        #expect(SlashMenu.action(for: "/resume") == .native(.resume))
        #expect(SlashMenu.action(for: "/config extra words") == .native(.config))
        #expect(SlashMenu.action(for: "/login") == .native(.login))
        #expect(SlashMenu.action(for: "/logout") == .native(.logout))
        #expect(SlashMenu.action(for: "/status") == .native(.status))
    }

    @Test func interactiveOnlyCommandsGiveTheNote() {
        #expect(SlashMenu.action(for: "/vim") == .note("/vim is not available in headless sessions"))
        #expect(SlashMenu.action(for: "/doctor") == .send)
        #expect(SlashMenu.action(for: "/doctor", terminalCommands: ["doctor"]) == .note("/doctor is not available in headless sessions"))
    }

    @Test func everythingElseSends() {
        for text in ["/agents", "/clear", "/rename x", "hello", "", "/"] { #expect(SlashMenu.action(for: text) == .send) }
    }

    @Test func movingClampsAtBothEnds() {
        #expect(SlashMenu.move(0, by: -1, count: 3) == 0)
        #expect(SlashMenu.move(0, by: 1, count: 3) == 1)
        #expect(SlashMenu.move(2, by: 1, count: 3) == 2)
        #expect(SlashMenu.move(0, by: 1, count: 0) == 0)
    }

    @Test func theHighlightedEntryIsClampedWhenTheListShrinks() {
        #expect(SlashMenu.highlighted(["a", "b", "c"], index: 1) == "b")
        #expect(SlashMenu.highlighted(["a"], index: 2) == "a")
        #expect(SlashMenu.highlighted([], index: 0) == nil)
    }
}
