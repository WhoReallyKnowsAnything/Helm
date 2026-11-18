import Foundation
import Testing
@testable import Helm

@Suite struct CadenceConfigCheckTests {
    private func get(_ planCheck: Bool = true, codeMap: Bool = false, extra: String = "", warnings: String = "[]") -> String {
        #"{"ok":true,"values":{"workflow.plan_check":\#(planCheck),"workflow.verifier":true,"planning.code_map":\#(codeMap),"review.triggers.plan.gate":"advisory","review.triggers.diff.gate":"off","review.triggers.risk_surface.gate":"blocking","review.triggers.phase_diff.gate":"off"\#(extra)},"warnings":\#(warnings)}"#
    }

    private func check(_ text: String, retry: @escaping () -> String = { "" }) throws -> CadenceConfigCheck {
        try CadenceConfigCheck.parse(text, retry: retry).get()
    }

    @Test func tableListsTheSevenKeysInOrder() {
        #expect(CadenceConfigCheck.recommended.map(\.key) == [
            "workflow.plan_check", "workflow.verifier", "planning.code_map", "review.triggers.plan.gate",
            "review.triggers.diff.gate", "review.triggers.risk_surface.gate", "review.triggers.phase_diff.gate"])
        #expect(CadenceConfigCheck.recommendedValue(for: "planning.code_map") == .bool(true))
        #expect(CadenceConfigCheck.recommendedValue(for: "workflow.skip_discuss") == nil)
    }

    @Test func liveValuesFlagOnlyCodeMap() throws {
        let result = try check(get(extra: #","roles.cad-reviewer.model":"sonnet","roles.cad-reviewer.effort":"medium""#))
        #expect(result.rows.filter(\.differs).map(\.key) == ["planning.code_map"])
        #expect(result.rows[2].current == .bool(false))
        #expect(result.reviewerModel == "sonnet" && result.reviewerEffort == "medium")
    }

    @Test func twoDifferingKeysAreFlaggedExactly() throws {
        #expect(try check(get(false)).rows.filter(\.differs).map(\.key) == ["workflow.plan_check", "planning.code_map"])
    }

    @Test func aMissingKeyIsUnsetAndFlagged() throws {
        let text = #"{"ok":true,"values":{"workflow.plan_check":true},"warnings":[]}"#
        let rows = try check(text).rows
        #expect(rows.count == 7)
        #expect(rows[1].current == nil && rows[1].differs)
    }

    @Test func unknownRoleKeyRetriesWithSevenKeysAndShowsUnknown() throws {
        let unknown = #"{"ok":false,"reason":"unknown-key","detail":["roles.cad-reviewer.model","roles.cad-reviewer.effort"],"hint":"x"}"#
        let result = try check(unknown, retry: { self.get() })
        #expect(result.rows.count == 7)
        #expect(result.reviewerModel == "unknown" && result.reviewerEffort == "unknown")
    }

    @Test func otherUnknownKeyFailsWithoutRetry() {
        let unknown = #"{"ok":false,"reason":"unknown-key","detail":["review.triggers"],"hint":"keys"}"#
        guard case .failure(let problem) = CadenceConfigCheck.parse(unknown, retry: { Issue.record("retried"); return "" }) else { Issue.record("expected failure"); return }
        #expect(problem.reason.contains("unknown-key") && problem.reason.contains("review.triggers"))
    }

    @Test func retiredKeyWarningTextIsReturned() throws {
        let result = try check(get(warnings: #"["config key \"model.effort.cad-executor\" was retired"]"#))
        #expect(result.warnings.first?.contains("retired") == true)
    }

    @Test func failureAndGarbageGiveAReasonAndNoRows() {
        for text in [#"{"ok":false,"reason":"bad"}"#, "garbage"] {
            guard case .failure = CadenceConfigCheck.parse(text, retry: { "" }) else { Issue.record("expected failure for \(text)"); return }
        }
    }
}
