import SwiftUI
import Testing
@testable import Helm

@MainActor
struct CommandSheetTests {
    @Test func eachNativeCommandSheetDraws() throws {
        let home = NSTemporaryDirectory() + "command-sheet-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        for command in SlashMenu.Native.allCases {
            let rep = try RenderSupport.render(
                CommandSheet(command: command, home: home, authRunner: { _ in (0, "", "") }, onClose: {}), .content(width: SheetWidth.medium))
            #expect(RenderSupport.distinctColours(rep) > 1, "\(command)")
        }
    }
}
