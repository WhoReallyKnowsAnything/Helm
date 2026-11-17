import AppKit
import Foundation
import Testing
@testable import OrchestratorGUI

struct NodeInfoTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let orchestratorNode = WorkerTreeNode(key: WorkerTree.orchestratorKey, kind: .orchestrator, title: "proj", taskTitle: nil, status: nil)
    static let workerNode = WorkerTreeNode(key: "alpha", kind: .worker, title: "alpha", taskTitle: nil, status: .running)
    static let nodes = [orchestratorNode, workerNode]

    /// A log entry folded from real result lines: the model id, the effort and the last iteration's tokens.
    static func entry(model: String = "claude-haiku-5-5", effort: String? = "high", tokens: Int = 420_000, age: TimeInterval = 1) -> SessionStatusStore.Entry {
        var fold = SessionStatusFold()
        fold.feed(#"{"type":"system","subtype":"init","model":"\#(model)"}"#)
        let text = effort.map { "Set effort level to \($0) (this session only)" } ?? "ok"
        fold.feed(#"{"type":"result","result":"\#(text)","usage":{"iterations":[{"input_tokens":\#(tokens),"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}]},"modelUsage":{"\#(model)":{"contextWindow":1000000}}}"#)
        return SessionStatusStore.Entry(fold: fold, modified: now.addingTimeInterval(-age))
    }

    static func row(model: String? = nil, effort: String? = nil) -> WorkerRow {
        WorkerRow(agentId: "alpha", status: "running", taskTitle: nil, lastEvent: nil, model: model, effort: effort)
    }

    static func lines(_ log: [String: SessionStatusStore.Entry], rows: [WorkerRow] = []) -> [String: [String]] {
        NodeInfo.lines(log: log, nodes: nodes, rows: rows)
    }

    @Test func aWorkerWithStreamDataShowsItsPercentAndModelLine() {
        #expect(Self.lines(["alpha": Self.entry()])["alpha"] == ["42%", "Haiku 5.5 · High"])
    }

    @Test func twoWorkersShowTheirOwnData() {
        let result = Self.lines([WorkerTree.orchestratorKey: Self.entry(model: "claude-sonnet-5-5", effort: "low", tokens: 100_000),
                                 "alpha": Self.entry()])
        #expect(result[WorkerTree.orchestratorKey] == ["10%", "Sonnet 5.5 · Low"])
        #expect(result["alpha"] == ["42%", "Haiku 5.5 · High"])
    }

    @Test func theEffortFallsBackToTheRowsLaunchValue() {
        #expect(Self.lines(["alpha": Self.entry(effort: nil)], rows: [Self.row(effort: "medium")])["alpha"] == ["42%", "Haiku 5.5 · Medium"])
    }

    @Test func theModelFallsBackToTheRowsModel() {
        var fold = SessionStatusFold()
        fold.feed(#"{"type":"rate_limit_event"}"#)
        let log = ["alpha": SessionStatusStore.Entry(fold: fold, modified: Self.now)]
        #expect(Self.lines(log, rows: [Self.row(model: "Opus 4.7", effort: "high")])["alpha"] == ["Opus 4.7 · High"])
    }

    @Test func aNodeWithoutDataShowsTheRowValuesOrNoData() {
        #expect(Self.lines([:], rows: [Self.row(model: "Opus 4.7", effort: "high")])["alpha"] == ["Opus 4.7 · High"])
        let result = Self.lines([:])
        #expect(result["alpha"] == ["no data"])
        #expect(result[WorkerTree.orchestratorKey] == ["no data"])
    }

    @Test func anOldLogStillShowsItsData() {
        #expect(Self.lines(["alpha": Self.entry(age: 300)])["alpha"] == ["42%", "Haiku 5.5 · High"])
    }

    @Test func aModelIdGetsAShortName() {
        #expect(NodeInfo.shortModel("claude-haiku-5-5") == "Haiku 5.5")
        #expect(NodeInfo.shortModel("claude-sonnet-5-5") == "Sonnet 5.5")
        #expect(NodeInfo.shortModel("claude-opus-4-7-20260101") == "Opus 4.7")
        #expect(NodeInfo.shortModel("claude-opus-4-7[1m]") == "Opus 4.7")
        #expect(NodeInfo.shortModel("weird") == "weird")
        #expect(NodeInfo.shortModel("") == nil)
    }

    @Test func theModelAndEffortLineFitsTheDefaultNodeWidth() {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        for text in ["Opus 4.7 · High", "Haiku 5.5 · Xhigh"] {
            let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
            #expect(width <= TreeLayout.nodeSize.width - 10)
        }
    }

    @Test func theDefaultNodeSizeHoldsFiveLines() {
        #expect(TreeLayout.nodeSize == CGSize(width: 260, height: 170))
    }
}
