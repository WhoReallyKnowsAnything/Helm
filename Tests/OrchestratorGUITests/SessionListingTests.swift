import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct SessionListingTests {
    private func win(_ session: String, _ name: String = "dashboard", _ path: String = "/Users/x/p") -> WindowEntry {
        WindowEntry(session: session, name: name, path: path, activity: 1, paneId: "%1")
    }

    private func rows(_ sessions: String, _ windows: [WindowEntry]) -> [SessionRow] {
        SessionListing.rows(sessions: SessionListing.parseSessions(sessions), windows: windows)
    }

    @Test func baseSessionWithGroupEqualToNameGivesRowAndItsClientNone() {
        let r = rows("a\ta\na-dashboard\ta\n", [win("a"), win("a-dashboard")])
        #expect(r.map(\.id) == ["a"])
    }

    @Test func prefixCollisionGivesFooAndFooBar() {
        let r = rows("foo\tfoo\nfoo-dashboard\tfoo\nfoo-bar\t\n", [win("foo"), win("foo-dashboard"), win("foo-bar")])
        #expect(r.map(\.id) == ["foo", "foo-bar"])
    }

    @Test func sessionWithoutDashboardWindowGivesNoRow() {
        #expect(rows("a\t\n", [win("a", "main")]).isEmpty)
    }

    @Test func titleIsLastPathComponent() {
        #expect(rows("a\t\n", [win("a", "dashboard", "/Users/x/Documents/proj")]).first?.title == "proj")
        #expect(rows("a\t\n", [win("a", "dashboard", "/Users/x")]).first?.title == "x")
    }

    @Test func emptyPathGivesSessionNameAsTitle() {
        #expect(rows("a\t\n", [win("a", "dashboard", "")]).first?.title == "a")
    }

    @Test func emptyInputGivesNoRows() {
        #expect(rows("", []).isEmpty)
    }

    @Test func windowLineKeepsPathAndPaneIdAndHasNoActivity() {
        let w = SessionListing.parseWindows("a\tdashboard\t/p\t%7\n")
        #expect(w == [WindowEntry(session: "a", name: "dashboard", path: "/p", paneId: "%7")])
        #expect(w[0].activity == nil)
    }

    @Test func windowListKeepsMainAndClientSessionWindows() {
        let w = SessionListing.parseWindows("a\tmain\t/p\t%1\na-dashboard\tdashboard\t/p\t%2\n")
        #expect(w.map(\.session) == ["a", "a-dashboard"])
        #expect(w.map(\.name) == ["main", "dashboard"])
    }

    @Test func aShortLineIsIgnored() {
        let w = SessionListing.parseWindows("a\tmain\t/p\t%1\nbad\tline\t/p\na\tdashboard\t/p\t%2\n")
        #expect(w.map(\.paneId) == ["%1", "%2"])
    }

    private func rootRows(_ sessions: String, _ windows: [WindowEntry], home: String) -> [SessionRow] {
        SessionListing.rows(sessions: SessionListing.parseSessions(sessions), windows: windows, home: home)
    }

    @Test func dashboardInTheHomeFolderIsRootAndAProjectInsideItIsNot() {
        let r = rootRows("a\t\nb\t\n", [win("a", "dashboard", "/Users/x"), win("b", "dashboard", "/Users/x/proj")], home: "/Users/x")
        #expect(r.map(\.isRootSession) == [true, false])
        #expect(r.map(\.title) == ["x", "proj"])
    }

    @Test func anotherSessionNameWithTheHomePathIsStillRoot() {
        #expect(rootRows("other\t\n", [win("other", "dashboard", "/Users/x")], home: "/Users/x").first?.isRootSession == true)
    }

    @Test func emptyPathIsNotRoot() {
        #expect(rootRows("a\t\n", [win("a", "dashboard", "")], home: "").first?.isRootSession == false)
    }

    @Test func aSymlinkAndATrailingSlashToTheHomeFolderAreRootButAnotherFolderIsNot() throws {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "root-rows-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        try fm.createDirectory(atPath: base + "/home", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/other", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/home")
        let r = rootRows("a\t\nb\t\nc\t\n",
                         [win("a", "dashboard", base + "/link"), win("b", "dashboard", base + "/home/"), win("c", "dashboard", base + "/other")],
                         home: base + "/home")
        #expect(r.map(\.isRootSession) == [true, true, false])
    }

    @Test @MainActor func theRunnerResultCarriesTheRootFlag() async {
        let home = NSHomeDirectory()
        let store = SessionStore { .listed(sessions: "r\t\np\t\n", windows: "r\tdashboard\t\(home)\t%1\np\tdashboard\t\(home)/proj\t%2\n") }
        await store.refresh()
        #expect(store.rows.map(\.isRootSession) == [true, false])
    }
}
