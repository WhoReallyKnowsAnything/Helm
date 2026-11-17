import Foundation
import Testing
@testable import OrchestratorGUI

@MainActor @Suite struct PromptBoxAttachmentTests {
    private func file(_ name: String, bytes: Int = 4) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    private final class Box: @unchecked Sendable { var files: [URL] = [] }

    private func model(_ box: Box = Box()) -> PromptBoxModel {
        PromptBoxModel(deliver: { _ in .sent }, deliverFiles: { _, files in box.files = files; return .sent })
    }

    @Test func attachListsDetachRemovesAndSendClears() async throws {
        let box = Box(), m = model(box)
        let a = try file("a.png"), b = try file("b.txt")
        m.attach([a, b, a])
        #expect(m.attachments == [a, b])
        m.detach(b)
        #expect(m.attachments == [a])
        await m.send("hi")
        #expect(box.files == [a] && m.sent && m.attachments.isEmpty)
    }

    @Test func oversizeImageIsLeftOutWithAClearMessage() throws {
        let m = model()
        m.attach([try file("big.png", bytes: PromptMessage.maxImageBytes + 1)])
        #expect(m.attachments.isEmpty)
        #expect(m.message?.contains("big.png") == true)
    }

    @Test func aFailedSendKeepsTheAttachments() async throws {
        let m = PromptBoxModel(deliver: { _ in .sent }, deliverFiles: { _, _ in .failed("no inbox") })
        let a = try file("a.png")
        m.attach([a])
        await m.send("hi")
        #expect(!m.sent && m.attachments == [a] && m.message == "no inbox")
    }

    @Test func aModelWithoutFileDeliveryRefusesDrops() throws {
        let m = PromptBoxModel(deliver: { _ in .sent })
        m.attach([try file("a.png")])
        #expect(m.attachments.isEmpty && m.message != nil)
    }
}
