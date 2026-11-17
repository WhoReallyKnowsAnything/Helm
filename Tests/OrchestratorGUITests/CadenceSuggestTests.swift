import XCTest
@testable import OrchestratorGUI

final class CadenceSuggestTests: XCTestCase {
    func testEmptyListGivesNone() throws {
        XCTAssertEqual(try CadenceSuggest.parse(#"{"ok":true,"suggestions":[]}"#).get(), [])
    }

    func testOnlySuggestKindCounts() throws {
        let json = #"{"ok":true,"suggestions":[{"kind":"suggest","subject":"a","evidence":"e"},{"kind":"info","subject":"b","evidence":"f"}]}"#
        XCTAssertEqual(try CadenceSuggest.parse(json).get(), [.init(subject: "a", evidence: "e")])
    }

    func testFailureAndGarbageGiveAReason() {
        for text in [#"{"ok":false,"reason":"no planning"}"#, "garbage", #"{"ok":true}"#, ""] {
            guard case .failure(let failure) = CadenceSuggest.parse(text) else { return XCTFail(text) }
            XCTAssertFalse(failure.reason.isEmpty)
        }
    }
}
