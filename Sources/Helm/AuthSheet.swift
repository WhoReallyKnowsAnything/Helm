import SwiftUI

/// What `claude auth status --json` prints, in the fields the sheet shows.
struct AuthStatus: Equatable {
    var loggedIn: Bool
    var method: String
    var expires: Date?

    static func parse(_ json: String) -> AuthStatus? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else { return nil }
        let text = object["loginExpiresAt"] as? String ?? ""
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return AuthStatus(loggedIn: loggedIn, method: object["authMethod"] as? String ?? "",
                          expires: fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text))
    }

    /// The rows the sheet draws, as `(label, value)`, so a test checks them without drawing.
    var rows: [(label: String, value: String)] {
        [("Logged in", loggedIn ? "yes" : "no")]
            + (method.isEmpty ? [] : [("Method", method)])
            + (expires.map { [("Expires", $0.formatted(date: .abbreviated, time: .shortened))] } ?? [])
    }
}

/// The `claude auth` runs behind `/login`, `/logout` and `/status`. The runner is injected, so tests start no process.
enum AuthFlow {
    typealias Runner = @Sendable ([String]) async throws -> (status: Int32, stdout: String, stderr: String)

    struct Outcome: Equatable {
        var status: AuthStatus?
        var failure: String?
    }

    static func status(_ run: Runner) async -> Outcome {
        do {
            let result = try await run(["auth", "status", "--json"])
            if let status = AuthStatus.parse(result.stdout) { return Outcome(status: status) }
            return Outcome(failure: lastLine(result.stderr) ?? "claude auth status printed no status.")
        } catch {
            return Outcome(failure: error.localizedDescription)
        }
    }

    /// Runs `auth login` or `auth logout`, then reads the status. A non-zero exit shows the last stderr line.
    static func change(_ verb: String, _ run: Runner) async -> Outcome {
        do {
            let result = try await run(["auth", verb])
            guard result.status == 0 else {
                return Outcome(failure: lastLine(result.stderr) ?? "claude auth \(verb) exited with status \(result.status).")
            }
        } catch {
            return Outcome(failure: error.localizedDescription)
        }
        return await status(run)
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
    }

    /// The real runner: `claude` from the user's shell PATH (EnvironmentCapture), stdin from /dev/null, off the main actor.
    static let claude: Runner = { arguments in
        try await Task.detached {
            let env = Dictionary(try EnvironmentCapture.capture().map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
            guard let path = (env["PATH"] ?? "").split(separator: ":").map({ "\($0)/claude" })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw EnvironmentCaptureFailure(reason: "claude is not on the PATH of your shell.")
            }
            // Login waits for the browser, so it gets a long timeout.
            let timeout: TimeInterval = arguments.contains("login") ? 600 : 30
            let result = ProcessRunner.run(path, arguments, environment: env, timeout: timeout)
            if let reason = result.startError { throw EnvironmentCaptureFailure(reason: reason) }
            if result.timedOut { throw EnvironmentCaptureFailure(reason: "claude \(arguments.joined(separator: " ")) did not finish in time.") }
            return (result.status, result.stdout, result.stderr)
        }.value
    }
}

/// The `/login`, `/logout` and `/status` content. Status reads on open; login and logout run only on a press.
struct AuthSheet: View {
    let mode: SlashMenu.Native
    let run: AuthFlow.Runner
    @Binding var failure: String?
    @Binding var progress: String?
    @State private var status: AuthStatus?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let status {
                ForEach(Array(status.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Space.md) {
                        Text(row.label).kitType(.body).foregroundStyle(Ink.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.value).kitType(.meta).foregroundStyle(Ink.textSecondary)
                    }
                    .textSelection(.enabled)
                }
            } else if mode == .login {
                KitNotice(text: "Sign in opens your browser.") {
                    Button("Sign In") { press("login", "Finish signing in in your browser") }.buttonStyle(.kitPrimary).disabled(running)
                }
            } else if mode == .logout {
                KitNotice(text: "Sign out of Claude Code on this Mac.") {
                    Button("Sign Out") { press("logout", "Signing out") }.buttonStyle(.kitPrimary).disabled(running)
                }
            }
        }
        .task {
            guard mode == .status, status == nil else { return }
            progress = "Reading the login status"
            show(await AuthFlow.status(run))
        }
    }

    private func press(_ verb: String, _ note: String) {
        guard !running else { return }
        running = true
        failure = nil
        progress = note
        Task {
            show(await AuthFlow.change(verb, run))
            running = false
        }
    }

    private func show(_ outcome: AuthFlow.Outcome) {
        progress = nil
        status = outcome.status
        failure = outcome.failure
    }
}
