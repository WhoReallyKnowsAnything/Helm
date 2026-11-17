import Foundation

/// One changed file of a pull request, as `gh pr list --json files` reports it.
struct PullRequestFile: Equatable {
    let path: String
    let additions: Int
    let deletions: Int
}

/// The pass, fail and pending counts of `statusCheckRollup`.
struct ChecksSummary: Equatable {
    var passed = 0
    var failed = 0
    var pending = 0

    /// "no checks" for an empty list. A green summary needs every entry to be understood and passed.
    var text: String {
        if passed + failed + pending == 0 { return "no checks" }
        return [(passed, "passed"), (failed, "failed"), (pending, "pending")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }

    fileprivate enum Kind { case passed, failed, pending }

    /// A `CheckRun` has `status` and `conclusion`, a `StatusContext` has `state`. Success, neutral and skipped pass.
    /// Failure, error, timed out, cancelled, action required and startup failure fail. Everything else, and every
    /// shape the code does not understand, is pending, so nothing unrecognised shows as green (D-15).
    fileprivate static func classify(status: String?, conclusion: String?, state: String?) -> Kind {
        func norm(_ text: String?) -> String { (text ?? "").uppercased().replacingOccurrences(of: " ", with: "_") }
        let status = norm(status), conclusion = norm(conclusion), state = norm(state)
        if !state.isEmpty {
            switch state {
            case "SUCCESS": return .passed
            case "FAILURE", "ERROR": return .failed
            default: return .pending
            }
        }
        guard status == "COMPLETED" else { return .pending }
        switch conclusion {
        case "SUCCESS", "NEUTRAL", "SKIPPED": return .passed
        case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failed
        default: return .pending
        }
    }
}

/// A worker's pull request (D-15). Built from the JSON of `gh pr list`; every field the app does not draw is ignored.
struct PullRequest: Equatable {
    let number: Int
    let url: String
    /// The raw `state`: OPEN, MERGED or CLOSED.
    let state: String
    let isDraft: Bool
    /// The raw `reviewDecision`. Empty when there is none.
    let reviewDecision: String
    let title: String
    let checks: ChecksSummary
    let files: [PullRequestFile]
    let changedFiles: Int

    /// A draft is open too: it has to be merged on GitHub, so the app must not merge it locally.
    var isOpen: Bool { state.uppercased() == "OPEN" }

    /// `files` holds fewer entries than the pull request changed, so the view says "showing N of M".
    var filesCapped: Bool { files.count < changedFiles }

    /// Plain lowercase words from the raw values, for example "open, changes requested".
    var stateWords: String {
        let base = isOpen && isDraft ? "draft" : state.lowercased()
        let review = reviewDecision.lowercased().replacingOccurrences(of: "_", with: " ")
        return review.isEmpty ? base : "\(base), \(review)"
    }

    static func decode(_ json: String) throws -> [PullRequest] {
        try JSONDecoder().decode([PullRequest].self, from: Data(json.utf8))
    }

    /// Prefers an open pull request, else the most recent. The requested fields hold no date, so the highest number wins.
    static func choose(from lists: [[PullRequest]]) -> PullRequest? {
        let all = lists.flatMap { $0 }
        return all.filter(\.isOpen).max { $0.number < $1.number } ?? all.max { $0.number < $1.number }
    }

    /// D-15: a URL the Open PR button may open. Only `https` on the host `github.com` passes. A port or a user
    /// part is refused too, so `https://github.com@evil.com` and `https://github.com:1/` open nothing.
    static func openableURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "github.com",
              parts.port == nil, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
}

extension PullRequestFile: Decodable {
    private enum Keys: String, CodingKey { case path, additions, deletions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            path: try c.decode(String.self, forKey: .path),
            additions: try c.decodeIfPresent(Int.self, forKey: .additions) ?? 0,
            deletions: try c.decodeIfPresent(Int.self, forKey: .deletions) ?? 0)
    }
}

extension PullRequest: Decodable {
    private enum Keys: String, CodingKey {
        case number, url, state, isDraft, reviewDecision, title, statusCheckRollup, files, changedFiles
    }

    /// One rollup entry. It never throws: an entry of a shape nobody expected still counts, as pending.
    private struct CheckEntry: Decodable {
        let status: String?, conclusion: String?, state: String?
        private enum Keys: String, CodingKey { case status, conclusion, state }

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: Keys.self)
            status = c.flatMap { try? $0.decodeIfPresent(String.self, forKey: .status) }
            conclusion = c.flatMap { try? $0.decodeIfPresent(String.self, forKey: .conclusion) }
            state = c.flatMap { try? $0.decodeIfPresent(String.self, forKey: .state) }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let rollup = try c.decodeIfPresent([CheckEntry].self, forKey: .statusCheckRollup) ?? []
        var summary = ChecksSummary()
        for entry in rollup {
            switch ChecksSummary.classify(status: entry.status, conclusion: entry.conclusion, state: entry.state) {
            case .passed: summary.passed += 1
            case .failed: summary.failed += 1
            case .pending: summary.pending += 1
            }
        }
        let files = try c.decodeIfPresent([PullRequestFile].self, forKey: .files) ?? []
        self.init(
            number: try c.decode(Int.self, forKey: .number),
            url: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
            state: try c.decodeIfPresent(String.self, forKey: .state) ?? "",
            isDraft: try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false,
            reviewDecision: try c.decodeIfPresent(String.self, forKey: .reviewDecision) ?? "",
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            checks: summary, files: files,
            changedFiles: try c.decodeIfPresent(Int.self, forKey: .changedFiles) ?? files.count)
    }
}
