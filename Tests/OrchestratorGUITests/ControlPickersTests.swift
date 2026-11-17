import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OrchestratorGUI

struct ControlPickersTests {
    private final class Calls: @unchecked Sendable { var models: [String] = []; var efforts: [String] = [] }

    private func picker(_ calls: Calls, model: String? = nil, effort: String? = nil, disabled: Bool = false) -> ControlPickerModel {
        ControlPickerModel(
            currentModel: model, currentEffort: effort, disabled: disabled,
            onModel: { calls.models.append($0) }, onEffort: { calls.efforts.append($0) })
    }

    @Test func everyValueTheModelChoicesSendIsInTheAcceptedListInModelsMd() throws {
        // ACCEPTED values from .planning/phases/3/MODELS.md, as of 389d46e^ (file pruned in 389d46e).
        let accepted = ["opus", "sonnet", "haiku", "opus[1m]", "sonnet[1m]"]
        let p = picker(Calls())
        #expect(p.models.map(ControlPickerModel.sentModel).allSatisfy(accepted.contains))
    }

    @Test func theEffortListIsTheFiveLevels() {
        #expect(picker(Calls()).efforts == ["low", "medium", "high", "xhigh", "max"])
    }

    @Test func theLabelsAreCapitalisedAndTheSentValuesStayLowercase() {
        let calls = Calls()
        let p = picker(calls)
        #expect(p.models.map(ControlPickerModel.label) == ["Opus", "Sonnet", "Haiku"])
        #expect(p.efforts.map(ControlPickerModel.label) == ["Low", "Medium", "High", "Xhigh", "Max"])
        p.pick(model: p.models[1]); p.pick(effort: p.efforts[2])
        #expect(calls.models == ["sonnet[1m]"] && calls.efforts == ["high"])
    }

    @Test func theCurrentValueIsMarked() {
        let p = picker(Calls(), model: "claude-haiku-5-5", effort: "high")
        #expect(p.models.filter(p.isCurrent(model:)) == ["haiku"])
        #expect(p.efforts.filter(p.isCurrent(effort:)) == ["high"])
        #expect(picker(Calls()).models.filter(picker(Calls()).isCurrent(model:)).isEmpty)
    }

    @Test func aOneMillionModelIdSelectsItsBaseChoiceAndOpusAndSonnetSendTheOneMillionName() {
        for (id, choice) in [("claude-opus-5-5[1m]", "opus"), ("claude-sonnet-5-5", "sonnet"), ("claude-haiku-5-5", "haiku")] {
            let p = picker(Calls(), model: id)
            #expect(p.models.filter(p.isCurrent(model:)) == [choice])
        }
        let calls = Calls()
        let p = picker(calls)
        p.models.forEach(p.pick(model:))
        #expect(calls.models == ["opus[1m]", "sonnet[1m]", "haiku"])
    }

    @MainActor @Test func theSubagentsButtonSitsLeftAndModelAndEffortInTheRightHalf() throws {
        var model = picker(Calls())
        model.subagentCount = 1
        let host = NSHostingView(rootView: ControlPickers(model: model).frame(width: 600, height: 40))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        host.layoutSubtreeIfNeeded()
        func leaves(_ view: NSView) -> [NSView] { view.subviews.isEmpty ? [view] : view.subviews.flatMap(leaves) }
        let xs = leaves(host).filter { $0 !== host && $0.frame.width > 0 }.map { host.convert($0.bounds, from: $0).minX }
        #expect(try #require(xs.min()) < 100)
        #expect(xs.filter { $0 > 300 }.count >= 2)
    }

    @Test func choosingCallsTheClosureOnceAndADisabledPickerCallsNothing() {
        let calls = Calls()
        picker(calls).pick(model: "opus")
        picker(calls).pick(effort: "low")
        #expect(calls.models == ["opus[1m]"] && calls.efforts == ["low"])
        let off = Calls()
        picker(off, disabled: true).pick(model: "opus")
        picker(off, disabled: true).pick(effort: "low")
        #expect(off.models.isEmpty && off.efforts.isEmpty)
    }
}
