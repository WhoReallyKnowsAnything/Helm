import SwiftUI
import Testing
@testable import OrchestratorGUI

@MainActor
struct McpSheetTests {
    @Test func theRowsAreTheInitServersInFileOrderAndTheSheetDraws() throws {
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines("init-mcp"))
        let rows = McpSheet.rows(parser.mcpServers)
        #expect(rows.count == 14)
        #expect(rows.first! == ("example", "connected", "user"))
        #expect(rows.map(\.name) == parser.mcpServers.map(\.name))
        #expect(rows.last! == ("example-14", "connected", "claudeai"))
        let sheet = CommandSheet(command: .mcp, mcpServers: parser.mcpServers, onClose: {})
        #expect(RenderSupport.distinctColours(try RenderSupport.render(sheet, .content(width: SheetWidth.medium))) > 1)
    }

    @Test func anEmptyListDraws() throws {
        let rep = try RenderSupport.render(McpSheet(servers: []), .fixed(CGSize(width: SheetWidth.medium, height: SheetWidth.small)))
        #expect(RenderSupport.distinctColours(rep) > 1)
    }
}
