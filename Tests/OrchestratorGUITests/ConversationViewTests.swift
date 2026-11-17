import SwiftUI
import Testing
@testable import OrchestratorGUI

@MainActor
struct ConversationViewTests {
    @Test func itemsFromTextTurnAndToolCallDrawMoreThanTheBackground() throws {
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines("text-turn"))
        parser.feed(try ConversationFixtures.lines("tool-call"))
        let rep = try RenderSupport.render(ConversationView(items: parser.items), .fixed(CGSize(width: 600, height: 300)))
        #expect(RenderSupport.distinctColours(rep) > 1)
    }

    private func draws(_ colour: Color, in rep: NSBitmapImageRep, tolerance: CGFloat = 4 / 255) throws -> Bool {
        let want = try #require(NSColor(colour).usingColorSpace(.sRGB))
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if abs(c.redComponent - want.redComponent) <= tolerance, abs(c.greenComponent - want.greenComponent) <= tolerance,
                   abs(c.blueComponent - want.blueComponent) <= tolerance { return true }
            }
        }
        return false
    }

    @Test func userAndAssistantRowsDrawTheirFillsAndTheBorder() throws {
        let items: [ConversationItem] = [.user(id: "u1", text: "hi"), .assistant(id: "a1", text: "hello", inProgress: false)]
        let rep = try RenderSupport.render(ConversationView(items: items), .fixed(CGSize(width: 600, height: 300)))
        #expect(try draws(Ink.youRowFill, in: rep))
        #expect(try draws(Ink.claudeRowFill, in: rep))
        #expect(try draws(Ink.border, in: rep))
    }

    private func groupSizes(_ items: [ConversationItem]) -> [Int] {
        ConversationView.displayRows(items).compactMap { if case .tools(_, let run) = $0 { return run.count } else { return nil } }
    }

    private func tool(_ id: String) -> ConversationItem { .tool(id: id, name: "Read", input: .null, result: nil) }

    @Test func editToolsGroupByRunOfConsecutiveToolItems() throws {
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines("edit-tools"))
        var expected: [Int] = []
        var run = 0
        for item in parser.items {
            if case .tool = item { run += 1 } else if run > 0 { expected.append(run); run = 0 }
        }
        if run > 0 { expected.append(run) }
        let sizes = groupSizes(parser.items)
        #expect(sizes == expected)
        #expect(sizes.reduce(0, +) == 3)
    }

    @Test func runsSplitOnAnythingButATool() {
        #expect(groupSizes([tool("t1"), tool("t2"), tool("t3")]) == [3])
        let text = ConversationItem.assistant(id: "a", text: "x", inProgress: false)
        #expect(groupSizes([tool("t1"), text, tool("t2")]) == [1, 1])
        let rows = ConversationView.displayRows([tool("t1"), tool("t2")])
        #expect(rows.first?.id == "t1")
    }

    @Test func statusLinesCapitaliseTheModelAndTheEffortForDisplayOnly() {
        #expect(ConversationView.statusDisplay("Set model to sonnet (claude-sonnet-5-5)") == "Set model to Sonnet (claude-sonnet-5-5)")
        #expect(ConversationView.statusDisplay("Set model to `haiku (claude-haiku-5-5)`") == "Set model to `Haiku (claude-haiku-5-5)`")
        #expect(ConversationView.statusDisplay("Set effort level to high (this session only): x") == "Set effort level to High (this session only): x")
        #expect(ConversationView.statusDisplay("something else") == "something else")
    }

    @Test func aPendingAskUserQuestionStaysOutsideTheCollapsedRun() {
        let ask = ConversationItem.tool(id: "q", name: "AskUserQuestion", input: .null, result: nil)
        let rows = ConversationView.displayRows([tool("t1"), ask, tool("t2")])
        #expect(rows.count == 3)
        if case .single(.tool(let id, _, _, _)) = rows[1] { #expect(id == "q") } else { Issue.record("question is not its own row") }
    }

    @Test func aStatusItemIsOneSingleRowAndSplitsNoToolRun() {
        let status = ConversationItem.status(id: "l1", text: "Set model to haiku")
        let rows = ConversationView.displayRows([status])
        #expect(rows.count == 1 && rows[0].id == "l1")
        #expect(groupSizes([tool("t1"), status, tool("t2")]) == [1, 1])
    }

    private var transcriptItems: [ConversationItem] {
        [
            .user(id: "u", text: "hi there"),
            .assistant(id: "a", text: "# Head\n\n- one\n- two\n\n```\nlet x = 1\n```\n\n| c1 | c2 |\n|---|---|\n| v1 | v2 |\n\n> quoted\n\nsee [link](https://x.test)", inProgress: false),
            .tool(id: "t/1", name: "Bash", input: .object(["command": .string("ls -la")]), result: ToolResult(text: "out", isError: false)),
            .status(id: "s", text: "done now"),
        ]
    }

    private let transcriptParts = ["you", "hi there", "claude", "Head", "one", "two", "let x = 1", "c1", "c2", "v1", "v2",
                                   "quoted", "link", "tools", "Bash ×1", "done now"]

    private func inOrder(_ text: String, _ parts: [String]) -> Bool {
        var rest = text[...]
        for part in parts {
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        return true
    }

    @Test func theTranscriptHoldsEveryTextInOrder() {
        let text = TranscriptText.build(transcriptItems, accent: Ink.accent, expanded: []).string
        #expect(inOrder(text, transcriptParts))
    }

    @Test func selectAllCopiesTheWholeTranscriptInOrder() throws {
        let scroll = TranscriptTextView.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 200)
        let textView = try #require(scroll.documentView as? NSTextView)
        let built = TranscriptText.build(transcriptItems, accent: Ink.accent, expanded: [])
        textView.textStorage?.setAttributedString(built)
        textView.selectAll(nil)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        // The modern `.string` type alone writes nothing offscreen; the writable types are what Cmd-C writes.
        #expect(textView.writeSelection(to: board, types: textView.writablePasteboardTypes))
        let copied = try #require(board.string(forType: .string))
        #expect(copied == built.string)
        #expect(inOrder(copied, transcriptParts))
    }

    @Test func aToolInputShowsOnlyWhenItsIdIsExpanded() {
        let input = formattedInput(.object(["command": .string("ls -la")]))
        #expect(!TranscriptText.build(transcriptItems, accent: Ink.accent, expanded: []).string.contains(input))
        #expect(!TranscriptText.build(transcriptItems, accent: Ink.accent, expanded: ["other"]).string.contains(input))
        let run = TranscriptText.runKey("t/1")
        // The call's input sits inside its run, so the run must be open too.
        #expect(!TranscriptText.build(transcriptItems, accent: Ink.accent, expanded: ["t/1"]).string.contains(input))
        #expect(!TranscriptText.build(transcriptItems, accent: Ink.accent, expanded: [run]).string.contains(input))
        #expect(TranscriptText.build(transcriptItems, accent: Ink.accent, expanded: ["t/1", run]).string.contains(input))
        #expect(TranscriptText.link(TranscriptText.toolScheme, "t/1").flatMap(TranscriptText.expandedKey) == "t/1")
        #expect(TranscriptText.link(TranscriptText.runScheme, "t/1").flatMap(TranscriptText.expandedKey) == run)
        #expect(URL(string: "https://x.test").flatMap(TranscriptText.expandedKey) == nil)
    }

    @Test func aToolGroupKeyIsTheMcpServerOrTheNativeName() {
        #expect(ConversationView.toolGroupKey("mcp__lean-ctx__ctx_read") == "lean-ctx")
        #expect(ConversationView.toolGroupKey("mcp__example_hosted__search") == "example_hosted")
        #expect(ConversationView.toolGroupKey("Bash") == "Bash")
        #expect(ConversationView.toolGroupKey("Read") == "Read")
    }

    @Test func toolGroupsCountAMixedRunInFirstSeenOrder() {
        let run = ["mcp__lean-ctx__ctx_read", "Bash", "mcp__lean-ctx__ctx_shell", "Read", "Bash", "mcp__lean-ctx__ctx_read"]
            .enumerated().map { ConversationItem.tool(id: "t\($0.offset)", name: $0.element, input: .null, result: nil) }
        let groups = ConversationView.toolGroups(run)
        #expect(groups.map(\.key) == ["lean-ctx", "Bash", "Read"])
        #expect(groups.map(\.count) == [3, 2, 1])
    }

    private func call(_ id: String, _ name: String, _ result: ToolResult?) -> ConversationItem {
        .tool(id: id, name: name, input: .object(["command": .string("ls " + id)]), result: result)
    }

    @Test func aRunSplitByAnotherItemGivesTwoCollapsedLines() {
        let items = [call("t1", "Bash", nil), .assistant(id: "a", text: "x", inProgress: false), call("t2", "Bash", nil)]
        let text = TranscriptText.build(items, accent: Ink.accent, expanded: []).string
        #expect(text.components(separatedBy: "Bash ×1").count - 1 == 2)
    }

    /// The VoiceOver buttons of the tool lines, as the transcript text view gives them: (label, value).
    private func toolButtons(_ items: [ConversationItem], expanded: Set<String>) throws -> [(String, String)] {
        let scroll = TranscriptTextView.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let textView = try #require(scroll.documentView as? TranscriptNSTextView)
        textView.textStorage?.setAttributedString(TranscriptText.build(items, accent: Ink.accent, expanded: expanded))
        textView.expanded = expanded
        return (textView.accessibilityChildren() ?? []).compactMap { $0 as? TranscriptNSTextView.ToolLineElement }.map { element in
            #expect(element.accessibilityRole() == .button)
            return (element.accessibilityLabel() ?? "", element.accessibilityValue() as? String ?? "")
        }
    }

    @Test func voiceOverReadsEachToolLineStateAndWhetherItIsExpanded() throws {
        let results: [(ToolResult?, String)] = [(nil, "running"), (ToolResult(text: "a", isError: false), "done"),
                                                (ToolResult(text: "e", isError: true), "failed")]
        for (result, state) in results {
            let items = [call("t1", "Bash", result)]
            let run = TranscriptText.runKey("t1")
            let collapsed = try toolButtons(items, expanded: [])
            #expect(collapsed.map(\.0) == ["Bash ×1"] && collapsed.map(\.1) == [state + ", collapsed"])
            let open = try toolButtons(items, expanded: [run])
            #expect(open.map(\.0) == ["Bash ×1", "Bash ls t1"])
            #expect(open.map(\.1) == [state + ", expanded", state + ", collapsed"])
            let both = try toolButtons(items, expanded: [run, "t1"])
            #expect(both.map(\.1) == [state + ", expanded", state + ", expanded"])
        }
        let mixed = [call("t1", "Bash", ToolResult(text: "a", isError: false)), call("t2", "Bash", nil)]
        #expect(try toolButtons(mixed, expanded: []).map(\.1) == ["running, collapsed"])
    }

    @Test func aCollapsedRunShowsTheSummaryAndItsKeyShowsTheCallLines() {
        let ok = ToolResult(text: "a", isError: false)
        let items = [call("t1", "mcp__lean-ctx__ctx_read", ok), call("t2", "mcp__lean-ctx__ctx_read", nil), call("t3", "Bash", ok)]
        let collapsed = TranscriptText.build(items, accent: Ink.accent, expanded: []).string
        #expect(collapsed.contains("› lean-ctx ×2 · Bash ×1"))
        #expect(!collapsed.contains("ls t1") && !collapsed.contains("ls t3"))
        let open = TranscriptText.build(items, accent: Ink.accent, expanded: [TranscriptText.runKey("t1")]).string
        #expect(inOrder(open, ["lean-ctx ×2 · Bash ×1", "mcp__lean-ctx__ctx_read ls t1", "mcp__lean-ctx__ctx_read ls t2", "Bash ls t3"]))
        let failed = TranscriptText.build([call("t1", "Bash", nil), call("t2", "Bash", ToolResult(text: "e", isError: true))],
                                          accent: Ink.accent, expanded: []).string
        #expect(failed.contains("✗ Bash ×2"))
        #expect(TranscriptText.build([call("t1", "Bash", ok)], accent: Ink.accent, expanded: []).string.contains("✓ Bash ×1"))
    }

    @Test func workingTextCountsWholeSecondsAndNeverGoesBelowZero() {
        #expect(WorkingLine.text(elapsed: 0) == "working… 0 Secs")
        #expect(WorkingLine.text(elapsed: 1) == "working… 1 Sec")
        #expect(WorkingLine.text(elapsed: 12) == "working… 12 Secs")
        #expect(WorkingLine.text(elapsed: -3) == "working… 0 Secs")
        #expect(WorkingLine.text(elapsed: 60) == "working… 1 Min 0 Secs")
        #expect(WorkingLine.text(elapsed: 61) == "working… 1 Min 1 Sec")
        #expect(WorkingLine.text(elapsed: 125) == "working… 2 Mins 5 Secs")
        #expect(WorkingLine.text(elapsed: 3600) == "working… 1 Hour 0 Mins 0 Secs")
        #expect(WorkingLine.text(elapsed: 4202) == "working… 1 Hour 10 Mins 2 Secs")
        #expect(WorkingLine.text(elapsed: 7200) == "working… 2 Hours 0 Mins 0 Secs")
    }

    @Test func theWorkingLineDrawsTheAccentOnlyWhileATurnHasAStart() throws {
        let blue = Ink.swatch(for: .blue)
        func line(_ start: Date?) throws -> NSBitmapImageRep {
            try RenderSupport.render(WorkingLine(startedAt: start).environment(\.kitAccent, blue), .fixed(CGSize(width: 300, height: 30)))
        }
        let glyph: CGFloat = 20 / 255
        #expect(try draws(blue.text, in: line(Date(timeIntervalSinceNow: -12)), tolerance: glyph))
        #expect(try !draws(blue.text, in: line(nil), tolerance: glyph))
    }

    /// The leftmost pixel column holding `colour`, scanning only the label columns so a Send button fill cannot match.
    private func leftmost(_ colour: Color, in rep: NSBitmapImageRep, width: CGFloat) throws -> Int? {
        let want = try #require(NSColor(colour).usingColorSpace(.sRGB))
        let scale = CGFloat(rep.pixelsWide) / width
        let limit = Int((Space.lg + Space.md + Metric.gutter) * scale)
        for x in 0..<limit {
            for y in 0..<rep.pixelsHigh {
                let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if abs(c.redComponent - want.redComponent) <= 20 / 255, abs(c.greenComponent - want.greenComponent) <= 20 / 255,
                   abs(c.blueComponent - want.blueComponent) <= 20 / 255 { return x }
            }
        }
        return nil
    }

    @Test func rowLabelsAndThePromptBoxLabelShareOneLeftEdge() throws {
        let width: CGFloat = 600
        let size = CGSize(width: width, height: 120)
        let accent = Ink.swatch(for: .blue)
        let you = try RenderSupport.render(
            ConversationView(items: [.user(id: "u", text: "hi")]).environment(\.kitAccent, accent), .fixed(size))
        let claude = try RenderSupport.render(
            ConversationView(items: [.assistant(id: "a", text: "hi", inProgress: false)]), .fixed(size))
        let tools = try RenderSupport.render(
            ConversationView(items: [.tool(id: "t", name: "Read", input: .null, result: nil)]), .fixed(size))
        let box = try RenderSupport.render(
            PromptBoxView(text: .constant(""), entries: [], enabled: true, onSend: {}).environment(\.kitAccent, accent),
            .fixed(size))
        let youX = try #require(try leftmost(accent.text, in: you, width: width))
        let boxX = try #require(try leftmost(accent.text, in: box, width: width))
        // 1 px slack: the same glyph antialiases differently on the card fill and the header ground.
        #expect(abs(youX - boxX) <= 1)
        // Different glyphs have different left bearings, so the other labels match within 2 px.
        let claudeX = try #require(try leftmost(Ink.textSecondary, in: claude, width: width))
        let toolsX = try #require(try leftmost(Ink.muted, in: tools, width: width))
        #expect(abs(claudeX - youX) <= 2 && abs(toolsX - youX) <= 2)
    }

    @Test func theWordClaudeFitsTheGutter() {
        let width = ("claude" as NSString).size(withAttributes: [.font: KitType.section.nsFont]).width
        #expect(width <= Metric.gutter)
    }

    @Test func aNilPathShowsTheNoOutLogNotice() throws {
        let rep = try RenderSupport.render(ConversationHost(path: nil), .fixed(CGSize(width: 400, height: 200)))
        #expect(RenderSupport.distinctColours(rep) > 1)
    }
}

@MainActor
struct ConversationHostSendTests {
    @Test func anEndedSessionKeepsItsHistoryWithADisabledBox() throws {
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines("text-turn"))
        let size = CGSize(width: 600, height: 300)
        let ended = try RenderSupport.render(
            VStack(spacing: Space.none) {
                ConversationView(items: parser.items)
                PromptBoxView(text: .constant(""), entries: [], enabled: false, message: nil, onSend: {})
            }, .fixed(size))
        let live = try RenderSupport.render(
            VStack(spacing: Space.none) {
                ConversationView(items: parser.items)
                PromptBoxView(text: .constant(""), entries: [], enabled: true, message: nil, onSend: {})
            }, .fixed(size))
        #expect(RenderSupport.distinctColours(ended) > 1)
        #expect(ended.tiffRepresentation != live.tiffRepresentation)
    }

    private func append(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func aSentMessageLandsInTheInboxAndTheReplayedReplyAppearsInTheStore() async throws {
        let dir = NSTemporaryDirectory() + "host-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let inbox = dir + "/in.jsonl", out = dir + "/out.jsonl"
        FileManager.default.createFile(atPath: inbox, contents: nil)
        FileManager.default.createFile(atPath: out, contents: nil)

        let store = ConversationStore(path: out)
        let model = ConversationHost.makeModel(inboxPath: inbox)
        await model.send("line one\nline two")
        #expect(model.sent)

        let lines = try String(contentsOfFile: inbox, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let message = try #require(object["message"] as? [String: Any])
        #expect(message["content"] as? String == "line one\nline two")

        // The orchestrator scripts replay the user line and the model replies in the out log.
        let user = #"{"type":"user","isReplay":true,"session_id":"s","message":{"content":"line one\nline two"}}"#
        let reply = #"{"type":"assistant","session_id":"s","message":{"id":"m1","content":[{"type":"text","text":"ok"}]}}"#
        try append(user + "\n" + reply + "\n", to: out)
        for _ in 0..<100 where store.items.count < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(store.items.count == 2)
    }

    @Test func noInboxPathFailsTheSend() async {
        let model = ConversationHost.makeModel(inboxPath: nil)
        await model.send("hi")
        #expect(!model.sent)
        #expect(model.message != nil)
    }
}

@MainActor
struct ConversationSnapshotTests {
    /// Renders in an explicit appearance and writes `screenshots/<name>.png` (AC8). The app forces dark (D-07), so light is a check
    /// that the kit tokens do not change with the system scheme.
    private func snap<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view.background(Ink.background).frame(width: size.width, height: size.height)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: RenderSupport.out, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: RenderSupport.out.appendingPathComponent("\(name).png"))
        return rep
    }

    private func conversation() throws -> some View {
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines("text-turn"))
        parser.feed(try ConversationFixtures.lines("edit-tools"))
        return VStack(spacing: Space.none) {
            ConversationView(items: parser.items)
            PromptBoxView(text: .constant("/"), entries: ["context", "model", "review"], enabled: true, message: nil, onSend: {})
        }
    }

    private func existingPage() -> some View {
        VStack(spacing: Space.md) {
            KitHoldCard(stateLine: "waiting on your choice", outcome: nil) {
                Text("Bash: rm -rf build").kitType(.body).foregroundStyle(Ink.text)
            } decision: {
                Button { } label: { KitLabel("Approve", icon: .done) }.buttonStyle(.kitPrimary)
            }
            Spacer()
            KitPromptBar(text: .constant(""), action: {})
        }
    }

    @Test func conversationAndAnExistingPageAreWrittenInLightAndDark() throws {
        let size = CGSize(width: 760, height: 520)
        let page = existingPage()
        let darkChat = try snap(conversation(), size: size, dark: true, name: "ac8-conversation-dark")
        let lightChat = try snap(conversation(), size: size, dark: false, name: "ac8-conversation-light")
        let darkPage = try snap(page, size: size, dark: true, name: "ac8-existing-dark")
        let lightPage = try snap(page, size: size, dark: false, name: "ac8-existing-light")
        for rep in [darkChat, lightChat, darkPage, lightPage] { #expect(RenderSupport.distinctColours(rep) > 1) }
        // Kit colours are fixed, so the scheme must not change a pixel.
        #expect(darkChat.tiffRepresentation == lightChat.tiffRepresentation)
        #expect(darkPage.tiffRepresentation == lightPage.tiffRepresentation)
    }

    @Test func diffBandsErrorIconAndListMarkersAreWrittenInLightAndDark() throws {
        let edit = JSONValue.object(["file_path": .string("a.txt"), "old_string": .string("one\ntwo\nthree"),
                                     "new_string": .string("one\n2\nthree\nfour")])
        let items: [ConversationItem] = [
            .tool(id: "e1", name: "Edit", input: edit, result: ToolResult(text: "ok", isError: false)),
            .tool(id: "b1", name: "Bash", input: .object(["command": .string("false")]), result: ToolResult(text: "exit 1", isError: true)),
            .assistant(id: "a1", text: "8. short\n9. a much longer item that has to wrap onto a second line so the hanging indent shows\n10. ten", inProgress: false),
        ]
        let view = TranscriptTextView(items: items, accent: Ink.accent, expanded: [TranscriptText.runKey("e1"), "e1", "b1"]) { _ in }
        let size = CGSize(width: 480, height: 420)
        let dark = try snap(view, size: size, dark: true, name: "transcript-gaps-dark")
        let light = try snap(view, size: size, dark: false, name: "transcript-gaps-light")
        #expect(RenderSupport.distinctColours(dark) > 3)
        #expect(dark.tiffRepresentation == light.tiffRepresentation)
    }
}

@MainActor
struct ConversationStreamingTests {
    private func assistantTexts(_ parser: ConversationParser) -> [String] {
        parser.items.compactMap { if case .assistant(_, let text, _) = $0 { return text } else { return nil } }
    }

    @Test func theInProgressTextAppearsOnceAndTheFinalEventReplacesIt() throws {
        let lines = try ConversationFixtures.lines("deltas")
        let finalIndex = try #require(lines.firstIndex { $0.hasPrefix(#"{"type":"assistant""#) })
        var parser = ConversationParser()
        parser.feed(Array(lines[..<finalIndex]))
        #expect(assistantTexts(parser) == ["hello there"])
        #expect(parser.items.contains { if case .assistant(_, _, true) = $0 { return true } else { return false } })
        parser.feed(Array(lines[finalIndex...]))
        #expect(assistantTexts(parser) == ["hello there"])
        #expect(!parser.items.contains { if case .assistant(_, _, true) = $0 { return true } else { return false } })
    }

    @Test func markdownAndCardsDrawMoreColoursThanThePlainView() throws {
        var parser = ConversationParser()
        parser.feed(try ConversationFixtures.lines("edit-tools"))
        parser.feed(try ConversationFixtures.lines("text-turn"))
        let rep = try RenderSupport.render(ConversationView(items: parser.items), .fixed(CGSize(width: 600, height: 400)))
        // The plain view of plan 1 drew text on the ground only; cards add the panel and the border.
        #expect(RenderSupport.distinctColours(rep) > 3)
    }
}
