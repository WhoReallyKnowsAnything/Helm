import Foundation

/// Loads a recorded stream-json fixture from `Fixtures/` and returns its non-empty lines.
enum ConversationFixtures {
    static func lines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
