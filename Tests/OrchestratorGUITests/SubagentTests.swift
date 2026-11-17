import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OrchestratorGUI

struct SubagentTests {
    private let parent = "toolu_01ChzizvUzYaZxJFWr4x5TGG"

    // Fixture line numbers (1-based in the file): 4 Agent tool_use, 6 task_started, 7 subagent prompt,
    // 9 subagent tool_use, 10 its tool_result, 11 task_updated completed, 13 Agent tool_result.
    private func lines() throws -> [String] { try ConversationFixtures.lines("subagent") }

    private func fold(_ lines: [String]) -> ConversationParser {
        var parser = ConversationParser()
        parser.feed(lines)
        return parser
    }

    @Test func subagentMessagesStayOutOfTheMainItems() throws {
        let items = fold(try lines()).items
        for item in items {
            if case .user = item { Issue.record("a user item leaked: \(item)") }
            if case .tool(_, let name, _, _) = item, name != "Agent" { Issue.record("a subagent tool leaked: \(name)") }
        }
        #expect(items.contains { if case .tool(_, "Agent", _, _) = $0 { true } else { false } })
    }

    @Test func theParserExposesTheSubagentWithItsOwnItems() throws {
        let agents = fold(try lines()).subagents
        let agent = try #require(agents.first)
        #expect(agents.count == 1 && agent.id == parent)
        #expect(agent.title == "count files" && agent.type == "general-purpose" && !agent.running)
        guard case .user(_, let prompt) = agent.items[0] else { Issue.record("no prompt first"); return }
        #expect(prompt.hasPrefix("Run `ls /tmp`"))
        guard case .tool(_, let name, _, let result) = agent.items[1] else { Issue.record("no tool second"); return }
        #expect(name == "mcp__example__tool_a" && result != nil)
    }

    @Test func aSubagentRunsUntilItsToolResultOrTaskUpdateArrives() throws {
        let all = try lines()
        #expect(fold(Array(all[0...8])).subagents.first?.running == true)
        #expect(fold(Array(all[0...9])).subagents.first?.running == true)
        #expect(fold([all[5], all[10]]).subagents.first?.running == false)
        #expect(fold([all[3], all[12]]).subagents.first?.running == false)
    }

    // subagent-background.jsonl: 0 Agent tool_use (run_in_background), 1 task_started (is_backgrounded),
    // 2 the immediate "Async agent launched" tool_result, 3-21 the subagent's own lines, 22 task_updated completed,
    // 23 task_notification completed.
    @Test func aBackgroundSubagentKeepsRunningPastItsLaunchResult() throws {
        let all = try ConversationFixtures.lines("subagent-background")
        #expect(fold(Array(all[0...2])).subagents.first?.running == true)
        let midway = fold(Array(all[0...21]))
        #expect(midway.subagents.first?.running == true)
        #expect(midway.subagents.first?.items.isEmpty == false)
        #expect(fold(Array(all[0...22])).subagents.first?.running == false)
        #expect(fold(all).subagents.first?.running == false)
    }

    @Test func aBackgroundSubagentEndsOnAnyTaskNotificationStatus() throws {
        let all = try ConversationFixtures.lines("subagent-background")
        for status in ["failed", "killed", "stopped"] {
            let ended = all[23].replacingOccurrences(of: "\"completed\"", with: "\"\(status)\"")
            #expect(fold(Array(all[0...21]) + [ended]).subagents.first?.running == false, "\(status)")
        }
    }

    @Test func aSubagentsAssistantTextIsItsOwnItem() throws {
        let text = #"{"type":"assistant","parent_tool_use_id":"\#(parent)","message":{"id":"m1","content":[{"type":"text","text":"hello"}]}}"#
        let parser = fold([text])
        #expect(parser.items.isEmpty)
        #expect(parser.subagents.first?.items == [.assistant(id: "m1#0", text: "hello", inProgress: false)])
    }

    @Test func aClearResetsTheSubagents() throws {
        var parser = fold(try lines())
        parser.feed(#"{"type":"system","subtype":"init","session_id":"another"}"#)
        #expect(parser.subagents.isEmpty)
    }

    private let restart = #"{"type":"system","subtype":"init","session_id":"f906d032-d928-4428-aa22-13d8d646459d"}"#

    @Test func aForegroundSubagentWithoutAResultEndsAtTheNextInit() throws {
        var parser = fold(Array(try lines()[0...8]))
        #expect(parser.subagents.first?.running == true)
        parser.feed(restart)
        #expect(parser.subagents.first?.running == false)
    }

    @Test func aBackgroundSubagentWithoutANotificationEndsAtTheNextInit() throws {
        var parser = fold(Array(try ConversationFixtures.lines("subagent-background")[0...21]))
        #expect(parser.subagents.first?.running == true)
        parser.feed(restart)
        #expect(parser.subagents.first?.running == false)
    }

    @Test func messagesBeforeTaskStartedStillGroupByParent() throws {
        let all = try lines()
        let early = fold([all[6], all[8]])
        #expect(early.subagents.count == 1 && early.subagents[0].items.count == 2 && early.subagents[0].title == "Subagent")
        let late = fold([all[6], all[8], all[5]])
        #expect(late.subagents.count == 1 && late.subagents[0].title == "count files" && late.subagents[0].items.count == 2)
    }

    @Test func aHeartbeatWithAParentIdChangesNothing() {
        let beat = #"{"type":"tool_progress","parent_tool_use_id":"toolu_x","tool_use_id":"toolu_x","session_id":"s"}"#
        #expect(fold([beat]).subagents.isEmpty)
    }

    @Test func theSubagentsButtonTitleShowsTheCountAndTheCallbackFires() {
        var opened = 0
        var model = ControlPickerModel(currentModel: nil, currentEffort: nil, onModel: { _ in }, onEffort: { _ in })
        model.onSubagents = { opened += 1 }
        #expect(model.subagentsTitle == "Subagents")
        model.subagentCount = 2
        #expect(model.subagentsTitle == "Subagents (2)")
        model.onSubagents(); model.onSubagents()
        #expect(opened == 2)
    }

    private func result(_ content: String, error: Bool) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(parent)","content":"\#(content)","is_error":\#(error)}]}}"#
    }

    @Test func aFailedOrInterruptedSubagentStopsRunningToo() throws {
        let started = try lines()[5]
        #expect(fold([started, result("boom", error: true)]).subagents.first?.running == false)
        #expect(fold([started, result("[Request interrupted by user]", error: true)]).subagents.first?.running == false)
    }

    @Test func onlyRunningSubagentsAreListed() throws {
        let all = try lines()
        #expect(fold(Array(all[0...8])).subagents.running.count == 1)
        #expect(fold(try lines()).subagents.running.isEmpty)
    }

    @Test func theSubagentsButtonShowsOnlyWhileOneRuns() {
        var model = ControlPickerModel(currentModel: nil, currentEffort: nil, onModel: { _ in }, onEffort: { _ in })
        #expect(!model.showsSubagents)
        model.subagentCount = 1
        #expect(model.showsSubagents)
    }

    @Test func theOpenPanelClosesWhenTheLastSubagentFinishes() {
        #expect(SubagentPanel.isOpen(true, running: 2))
        #expect(!SubagentPanel.isOpen(true, running: 0))
        #expect(!SubagentPanel.isOpen(false, running: 2))
    }

    @MainActor @Test func hidingTheButtonKeepsModelAndEffortOnTheRight() throws {
        let model = ControlPickerModel(currentModel: nil, currentEffort: nil, onModel: { _ in }, onEffort: { _ in })
        let host = NSHostingView(rootView: ControlPickers(model: model).frame(width: 600, height: 40))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        host.layoutSubtreeIfNeeded()
        func leaves(_ view: NSView) -> [NSView] { view.subviews.isEmpty ? [view] : view.subviews.flatMap(leaves) }
        let xs = leaves(host).filter { $0 !== host && $0.frame.width > 0 }.map { host.convert($0.bounds, from: $0).minX }
        #expect(xs.filter { $0 > 300 }.count >= 2)
    }

    @MainActor @Test func aKitButtonKeepsTheCapitalsOfItsLabel() throws {
        func image<S: ButtonStyle>(_ title: String, _ style: S) throws -> Data? {
            try RenderSupport.render(Button(title) {}.buttonStyle(style), .fixed(CGSize(width: 120, height: 40))).tiffRepresentation
        }
        #expect(try image("Model", .kit) != image("model", .kit))
    }
}
