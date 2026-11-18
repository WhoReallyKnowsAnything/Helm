import SwiftUI
import Testing
@testable import Helm

@MainActor
struct ResumeSheetTests {
    private func render(rows: [ResumeRow]?, canResume: Bool = true) throws -> Int {
        let sheet = ResumeSheet(
            cwd: "/tmp", sessionId: "b", projects: NSTemporaryDirectory() + "none-" + UUID().uuidString,
            relaunch: canResume ? { _ in } : nil, failure: .constant(nil), progress: .constant(nil), onDone: {}, rows: rows)
        return RenderSupport.distinctColours(try RenderSupport.render(sheet, .content(width: SheetWidth.medium)))
    }

    @Test func threeRowsWithOneCurrentDraw() throws {
        let rows = ["a", "b", "c"].map { ResumeRow(id: $0, title: "title " + $0, date: Date(), isCurrent: $0 == "b") }
        #expect(try render(rows: rows) > 1)
    }

    @Test func anEmptyListDrawsItsNotice() throws { #expect(try render(rows: []) > 1) }

    @Test func aWorkerDrawsOnlyTheNote() throws { #expect(try render(rows: nil, canResume: false) > 1) }

    @Test func theResumeRuleFollowsTheNode() {
        #expect(ResumeTarget.choose(root: true, worker: nil, folder: nil) == .root)
        #expect(ResumeTarget.choose(root: false, worker: nil, folder: "/p") == .folder("/p"))
        #expect(ResumeTarget.choose(root: false, worker: "w1", folder: "/p") == nil)
        #expect(ResumeTarget.choose(root: false, worker: nil, folder: nil) == nil)
    }
}
