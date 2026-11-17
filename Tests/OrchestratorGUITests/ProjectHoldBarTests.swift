import Foundation
import Testing
@testable import OrchestratorGUI

/// The bar above every project terminal lists the holds and requests of every worker of the project.
@MainActor
struct ProjectHoldBarTests {
    private final class Calls {
        var decided: [String] = []
    }

    private static func hold(_ id: String, _ label: String) -> GateHold {
        GateHold(id: id, label: label, hash: String(repeating: "a", count: 64), epoch: 100, state: .live, command: "Bash: git push \(id)")
    }

    private static let a = hold("h1", "alpha")
    private static let b = hold("h2", "bravo")

    @Test func aHoldOfOneWorkerIsInTheBarOfEveryTerminal() throws {
        let bar = try #require(ProjectHoldBar(holds: [Self.a, Self.b], root: false))
        #expect(bar.entries.map(\.worker) == ["alpha", "bravo"])
        #expect(bar.entries[0].holds == [Self.a])
        #expect(bar.entries[1].holds == [Self.b])
    }

    @Test func aPressDecidesOnlyTheHoldOfThatCard() throws {
        let bar = try #require(ProjectHoldBar(holds: [Self.a, Self.b], root: false))
        let calls = Calls()
        let cards = HoldCards(
            holds: bar.entries[0].holds,
            card: { HoldStore.Card(command: $0.command, stateLine: nil, outcome: nil, showsButtons: true, enabled: true) },
            onDecide: { key, choice in calls.decided.append("\(key) \(choice.rawValue)") })
        cards.press(bar.entries[0].holds[0], .allow)
        #expect(calls.decided == ["\(Self.a.key) allow"])
    }

    @Test func theBarOfOneProjectHoldsNothingOfAnother() throws {
        let one = try #require(ProjectHoldBar(holds: [Self.a], root: false))
        let two = try #require(ProjectHoldBar(holds: [Self.b], root: false))
        #expect(one.entries.flatMap(\.holds) == [Self.a])
        #expect(two.entries.flatMap(\.holds) == [Self.b])
    }

    @Test func nothingPendingGivesNoBar() {
        #expect(ProjectHoldBar(holds: [], root: false) == nil)
    }

    @Test func aRootSessionGivesNoBar() {
        #expect(ProjectHoldBar(holds: [Self.a], root: true) == nil)
    }

    private static func entry(_ node: String) -> RequestStore.Entry {
        var fold = ControlRequests()
        fold.feed(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{},"tool_use_id":"t1"}}"#)
        return RequestStore.Entry(key: "request:\(node):r1", nodeKey: node, request: fold.pending[0], live: true)
    }

    @Test func aBarWithOnlyARequestListsItsNode() throws {
        let bar = try #require(ProjectHoldBar(holds: [], requests: [Self.entry("alpha")], root: false))
        #expect(bar.entries.map(\.worker) == ["alpha"])
        #expect(bar.entries[0].requests.count == 1)
    }

    @Test func aHoldAndARequestShareOneNodeEntry() throws {
        let bar = try #require(ProjectHoldBar(holds: [Self.a], requests: [Self.entry("alpha")], root: false))
        #expect(bar.entries.map(\.worker) == ["alpha"])
        #expect(bar.entries[0].holds == [Self.a] && bar.entries[0].requests.count == 1)
    }

    private static func question(_ node: String) -> RequestStore.Entry {
        var fold = ControlRequests()
        fold.feed(#"{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which?","header":"H","multiSelect":false,"options":[{"label":"A","description":"a"},{"label":"B","description":"b"}]}]},"tool_use_id":"toolu_1"}}"#)
        return RequestStore.Entry(key: "request:\(node):q1", nodeKey: node, request: fold.pending[0], live: true)
    }

    @Test func aRootSessionWithARequestGivesABarWithoutHolds() throws {
        let bar = try #require(ProjectHoldBar(holds: [Self.a], requests: [Self.entry("dashboard")], root: true))
        #expect(bar.entries.map(\.worker) == ["dashboard"])
        #expect(bar.entries[0].requests.count == 1)
        #expect(bar.entries.flatMap(\.holds).isEmpty)
    }

    @Test func aRootSessionsOwnQuestionGivesACard() throws {
        let bar = try #require(ProjectHoldBar(holds: [], requests: [Self.question("dashboard")], root: true))
        #expect(bar.entries[0].requests.count == 1)
    }

    @Test func aDashboardSessionsOwnQuestionGivesACard() throws {
        let bar = try #require(ProjectHoldBar(holds: [], requests: [Self.question("dashboard")], root: false))
        #expect(bar.entries[0].requests.count == 1)
    }

    @Test func aRootSessionWithOnlyHoldsGivesNoBar() {
        #expect(ProjectHoldBar(holds: [Self.a, Self.b], requests: [], root: true) == nil)
    }
}
