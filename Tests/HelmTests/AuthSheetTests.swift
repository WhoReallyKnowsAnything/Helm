import SwiftUI
import Testing
@testable import Helm

/// Records each call and answers from a table, so no test starts a real `claude` process.
private final class FakeAuth: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String]] = []
    let answers: [String: (status: Int32, stdout: String, stderr: String)]

    init(_ answers: [String: (status: Int32, stdout: String, stderr: String)]) { self.answers = answers }

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return log }

    var runner: AuthFlow.Runner {
        { [self] arguments in
            lock.lock(); log.append(arguments); lock.unlock()
            return answers[arguments.joined(separator: " ")] ?? (0, "", "")
        }
    }
}

@MainActor
struct AuthSheetTests {
    static let statusJSON = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","loginExpiresAt":"2026-11-11T00:37:53.327Z"}"#
    let status = ["auth status --json": (status: Int32(0), stdout: statusJSON, stderr: "")]

    @Test func statusJSONRendersMethodAndExpiry() async {
        let fake = FakeAuth(status)
        let outcome = await AuthFlow.status(fake.runner)
        let rows = try? #require(outcome.status).rows
        #expect(rows?.map(\.label) == ["Logged in", "Method", "Expires"])
        #expect(rows?.first?.value == "yes" && rows?[1].value == "claude.ai")
        let expected = try? #require(ISO8601DateFormatter().date(from: "2026-11-11T00:37:53Z"))
        #expect(abs((outcome.status?.expires?.timeIntervalSince1970 ?? 0) - (expected?.timeIntervalSince1970 ?? 0) - 0.327) < 0.01)
        #expect(fake.calls == [["auth", "status", "--json"]])
    }

    @Test func loginRunsLoginThenStatus() async {
        let fake = FakeAuth(status)
        let outcome = await AuthFlow.change("login", fake.runner)
        #expect(fake.calls == [["auth", "login"], ["auth", "status", "--json"]])
        #expect(outcome.status?.loggedIn == true && outcome.failure == nil)
    }

    @Test func logoutRunsNothingUntilTheConfirmPress() async throws {
        let fake = FakeAuth(status)
        _ = try RenderSupport.render(
            AuthSheet(mode: .logout, run: fake.runner, failure: .constant(nil), progress: .constant(nil)), .content(width: SheetWidth.medium))
        #expect(fake.calls.isEmpty)
        _ = await AuthFlow.change("logout", fake.runner)
        #expect(fake.calls == [["auth", "logout"], ["auth", "status", "--json"]])
    }

    @Test func aNonZeroExitShowsItsLastStderrLine() async {
        let fake = FakeAuth(["auth login": (status: 1, stdout: "", stderr: "Opening browser\nLogin failed: timed out\n")])
        let outcome = await AuthFlow.change("login", fake.runner)
        #expect(outcome.failure == "Login failed: timed out" && outcome.status == nil)
        #expect(fake.calls == [["auth", "login"]])
    }
}
