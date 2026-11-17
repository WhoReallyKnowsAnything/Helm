import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct CadenceConfigTests {
    private var values: String {
        let roles = CadenceConfig.agents.map { #""roles.\#($0).model":"sonnet","roles.\#($0).effort":"high""# }.joined(separator: ",")
        return #"{"ok":true,"values":{"workflow.skip_discuss":false,"workflow.plan_check":true,\#(roles)},"warnings":["retired key"]}"#
    }

    @Test func valuesParseAndWarningsAreIgnored() throws {
        let config = try CadenceConfig.parse(values).get()
        #expect(config.skipDiscuss == false)
        #expect(config.planCheck == true)
        #expect(config.roles.count == 5)
        #expect(config.roles["cad-executor"] == .init(model: "sonnet", effort: "high"))
    }

    @Test func okFalseSurfacesReasonAndHint() {
        let json = #"{"ok":false,"reason":"unknown-key","detail":["x"],"hint":"run keys"}"#
        guard case .failure(let f) = CadenceConfig.parse(json) else { Issue.record("expected failure"); return }
        #expect(f.reason.contains("unknown-key"))
        #expect(f.reason.contains("run keys"))
    }

    @Test func missingValueAndGarbageGiveReasons() {
        guard case .failure = CadenceConfig.parse(#"{"ok":true,"values":{"workflow.skip_discuss":false}}"#) else { Issue.record("expected failure"); return }
        guard case .failure = CadenceConfig.parse("boom") else { Issue.record("expected failure"); return }
    }

    @Test func auditCounts() throws {
        #expect(try CadenceConfig.parseAudit(#"{"ok":true,"counts":{"total":12,"broken":12},"requirements":[]}"#).get() == 12)
        #expect(try CadenceConfig.parseAudit(#"{"ok":true,"counts":{"total":2,"broken":0}}"#).get() == 0)
        guard case .failure = CadenceConfig.parseAudit(#"{"ok":false,"reason":"no-planning-dir"}"#) else { Issue.record("expected failure"); return }
        guard case .failure = CadenceConfig.parseAudit("") else { Issue.record("expected failure"); return }
    }
}
