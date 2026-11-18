import Foundation
import Testing
@testable import Helm

struct InboxDeliveryTests {
    private func tempInbox() throws -> String {
        let path = NSTemporaryDirectory() + "inbox-\(UUID().uuidString).jsonl"
        try Data().write(to: URL(fileURLWithPath: path))
        return path
    }

    private func lines(_ path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func content(_ line: String) throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "user")
        let message = try #require(object["message"] as? [String: Any])
        return try #require(message["content"] as? String)
    }

    @Test func twoSendsGiveExactlyTwoLines() throws {
        let path = try tempInbox()
        #expect(InboxDelivery.append("one", inbox: path) == .sent)
        #expect(InboxDelivery.append("two", inbox: path) == .sent)
        let all = try lines(path)
        #expect(all.count == 2)
        #expect(try content(all[0]) == "one")
        #expect(try content(all[1]) == "two")
    }

    @Test func newlineTabQuoteAndEmojiRoundTripOnOnePhysicalLine() throws {
        let path = try tempInbox()
        let text = "line one\nline\ttwo \"quoted\" \u{1F600}"
        #expect(InboxDelivery.append(text, inbox: path) == .sent)
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        #expect(raw.filter { $0 == "\n" }.count == 1)
        #expect(try content(try #require(lines(path).first)) == text)
    }

    @Test func aLongTextIsDeliveredWhole() throws {
        let path = try tempInbox()
        let text = String(repeating: "a", count: 5_000)
        #expect(InboxDelivery.append(text, inbox: path) == .sent)
        #expect(try content(try #require(lines(path).first)) == text)
    }

    @Test func emptyAndWhitespaceTextIsRefusedAndLeavesTheFileAlone() throws {
        let path = try tempInbox()
        for text in ["", "  \n\t "] {
            if case .refused = InboxDelivery.append(text, inbox: path) {} else { Issue.record("expected refused") }
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8).isEmpty)
    }

    @Test func aMissingInboxFailsAndCreatesNoFile() {
        let path = NSTemporaryDirectory() + "missing-\(UUID().uuidString).jsonl"
        if case .failed = InboxDelivery.append("hi", inbox: path) {} else { Issue.record("expected failed") }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: cleaning and the orchestrator-row deliver, moved from the old pane-delivery tests

    @Test func aSemicolonIsKept() {
        #expect(InboxDelivery.clean("a;b") == "a;b")
    }

    @Test func newlineTabAndCarriageReturnBecomeSingleSpaces() {
        #expect(InboxDelivery.clean("a\nb\tc\rd") == "a b c d")
    }

    @Test func anEscapeSequenceLosesItsEscByte() throws {
        let cleaned = try #require(InboxDelivery.clean("x\u{1B}[31mred"))
        #expect(!cleaned.unicodeScalars.contains { $0.value == 0x1B })
        #expect(cleaned == "x[31mred")
    }

    @Test func aLongTextIsCutTo200Characters() {
        #expect(InboxDelivery.clean(String(repeating: "a", count: 500))?.count == 200)
    }

    @Test func theRequestCapIs2000AndThePickCapStays200() {
        #expect(InboxDelivery.requestMaxLength == 2000)
        #expect(InboxDelivery.maxLength == 200)
    }

    @Test func aCapRaisesTheCutAndKeepsTheCleaning() throws {
        let cap = InboxDelivery.requestMaxLength
        #expect(InboxDelivery.clean(String(repeating: "a", count: 2500), cap: cap)?.count == 2000)
        let text = String(repeating: "ab\r\ncd\tef\n", count: 150)
        let cleaned = try #require(InboxDelivery.clean(text, cap: cap))
        #expect(cleaned.unicodeScalars.count == text.unicodeScalars.count)
        #expect(cleaned.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
    }

    @Test func nothingLeftReturnsNil() {
        #expect(InboxDelivery.clean("") == nil)
        #expect(InboxDelivery.clean("  \n ") == nil)
        #expect(InboxDelivery.clean("\u{1B}\u{07}") == nil)
    }

    // MARK: delivery to the inbox, with a private tmux server for the window lookup

    private func tmux(_ socket: String, _ args: [String]) -> ProcessResult {
        guard let path = OrchestratorPaths.tmuxPath() else { return ProcessResult(status: -1, stdout: "", stderr: "") }
        return ProcessRunner.run(path, ["-L", socket] + args, environment: TmuxRunner.environment(), timeout: 5)
    }

    private func newSocket() -> String { "gui-test-\(UUID().uuidString.prefix(8).lowercased())" }

    private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    /// A fixture project whose `dashboard` row stores a temp inbox file, and a session `proj` whose `window`
    /// has that project as its path. `storePath: false` leaves the stored path NULL.
    private func setUp(socket: String, window: String = "dashboard", storePath: Bool = true) throws -> (fx: FixtureProject, inbox: String) {
        let fx = try FixtureProject.make()
        let inbox = fx.path + "/dashboard.in.jsonl"
        FileManager.default.createFile(atPath: inbox, contents: nil)
        if storePath { try fx.sql("UPDATE sessions SET inbox_path = '\(inbox)' WHERE agent_id = 'dashboard'") }
        else { try fx.sql("UPDATE sessions SET inbox_path = NULL WHERE agent_id = 'dashboard'") }
        _ = tmux(socket, ["new-session", "-d", "-x", "200", "-y", "60", "-s", "proj", "-n", window, "-c", fx.path, "sleep 60"])
        return (fx, inbox)
    }

    private func content(ofLine line: String) throws -> String {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "user")
        let message = try #require(object["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        return try #require(message["content"] as? String)
    }

    @Test func deliversExactlyOneStreamJsonLine() throws {
        let socket = newSocket()
        defer { _ = tmux(socket, ["kill-server"]) }
        let (fx, inbox) = try setUp(socket: socket)
        defer { fx.remove() }
        let line = "Pick up the Notion task: Fix; the thing"
        #expect(InboxDelivery.deliver(line, base: "proj", socket: socket) == .sent)
        let text = read(inbox)
        #expect(text.hasSuffix("\n") && text.split(separator: "\n").count == 1)
        #expect(try content(ofLine: text) == line)
    }

    @Test func twoDeliveriesGiveTwoLinesInOrder() throws {
        let socket = newSocket()
        defer { _ = tmux(socket, ["kill-server"]) }
        let (fx, inbox) = try setUp(socket: socket)
        defer { fx.remove() }
        #expect(InboxDelivery.deliver("first", base: "proj", socket: socket) == .sent)
        #expect(InboxDelivery.deliver("second", base: "proj", socket: socket) == .sent)
        let lines = read(inbox).split(separator: "\n").map(String.init)
        #expect(try lines.map(content(ofLine:)) == ["first", "second"])
    }

    @Test func quotesBackslashAndSemicolonRoundTrip() throws {
        let socket = newSocket()
        defer { _ = tmux(socket, ["kill-server"]) }
        let (fx, inbox) = try setUp(socket: socket)
        defer { fx.remove() }
        let line = #"say "hi" \n C:\dir; echo 'x' $(y) `z`;"#
        #expect(InboxDelivery.deliver(line, base: "proj", socket: socket) == .sent)
        #expect(try content(ofLine: read(inbox)) == line)
    }

    @Test func aBaseWithoutADashboardWindowFailsAndWritesNothing() throws {
        let socket = newSocket()
        defer { _ = tmux(socket, ["kill-server"]) }
        let (fx, inbox) = try setUp(socket: socket, window: "work")
        defer { fx.remove() }
        guard case .failed = InboxDelivery.deliver("hello", base: "proj", socket: socket) else {
            Issue.record("expected a failure"); return
        }
        #expect(read(inbox) == "")
    }

    @Test func aLineWithAControlCharacterOrNoTextIsRefusedAndWritesNothing() throws {
        let socket = newSocket()
        defer { _ = tmux(socket, ["kill-server"]) }
        let (fx, inbox) = try setUp(socket: socket)
        defer { fx.remove() }
        for line in ["a\u{1B}[31m", "a\nb", ""] {
            guard case .refused = InboxDelivery.deliver(line, base: "proj", socket: socket) else {
                Issue.record("expected a refusal for \(line.debugDescription)"); return
            }
        }
        #expect(read(inbox) == "")
    }

    @Test func aNullStoredPathFailsAndWritesNothing() throws {
        let socket = newSocket()
        defer { _ = tmux(socket, ["kill-server"]) }
        let (fx, inbox) = try setUp(socket: socket, storePath: false)
        defer { fx.remove() }
        guard case .failed = InboxDelivery.deliver("hello", base: "proj", socket: socket) else {
            Issue.record("expected a failure"); return
        }
        #expect(read(inbox) == "")
    }

    @Test func aDeletedInboxFailsAndIsNotRecreated() throws {
        let socket = newSocket()
        defer { _ = tmux(socket, ["kill-server"]) }
        let (fx, inbox) = try setUp(socket: socket)
        defer { fx.remove() }
        try FileManager.default.removeItem(atPath: inbox)
        guard case .failed = InboxDelivery.deliver("hello", base: "proj", socket: socket) else {
            Issue.record("expected a failure"); return
        }
        #expect(!FileManager.default.fileExists(atPath: inbox))
    }
}
