import Foundation
import Testing
@testable import Helm

@MainActor
struct ReplyLatencyTests {
    private func lastAssistantText(_ store: ConversationStore) -> String? {
        if let last = store.items.last, case .assistant(_, let text, _) = last { return text }
        return nil
    }

    private func history(turns: Int) -> String {
        var out = ""
        for n in 0..<turns {
            out += "{\"type\":\"user\",\"isReplay\":true,\"session_id\":\"s\",\"message\":{\"content\":\"question \(n)\"}}\n"
            out += "{\"type\":\"assistant\",\"session_id\":\"s\",\"message\":{\"id\":\"mt\(n)\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tu\(n)\",\"name\":\"Read\",\"input\":{\"path\":\"c.txt\"}}]}}\n"
            out += "{\"type\":\"user\",\"session_id\":\"s\",\"message\":{\"content\":[{\"tool_use_id\":\"tu\(n)\",\"type\":\"tool_result\",\"content\":[{\"type\":\"text\",\"text\":\"alpha\\nbeta\\ngamma\\n\"}]}]}}\n"
            out += "{\"type\":\"assistant\",\"session_id\":\"s\",\"message\":{\"id\":\"mx\(n)\",\"content\":[{\"type\":\"text\",\"text\":\"reply \(n)\"}]}}\n"
            out += "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"s\",\"stop_reason\":\"end_turn\"}\n"
        }
        return out
    }

    private func waitFor(timeout: Duration = .seconds(2), _ what: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !what(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        return what()
    }

    private func millis(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    // Timed apart from the suite: other tests hold the main actor for seconds, which this wall-clock check would count.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORCH_PERF"] == "1", "Main-actor timing; parallel suites starve the main actor. Run: ORCH_PERF=1 swift test --filter ReplyLatency")) func firstReplyTextShowsWithinFiftyMillisecondsOnALongHistory() async throws {
        let dir = NSTemporaryDirectory() + "latency-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        try Data(history(turns: 150).utf8).write(to: URL(fileURLWithPath: out))
        let store = ConversationStore(path: out)
        #expect(await waitFor(timeout: .seconds(10)) { lastAssistantText(store) == "reply 149" })

        let handle = try #require(FileHandle(forWritingAtPath: out))
        defer { try? handle.close() }
        let clock = ContinuousClock()
        var samples: [Double] = []
        for n in 0..<20 {
            let marker = "marker\(n)"
            let delta = "{\"type\":\"stream_event\",\"session_id\":\"s\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\(marker)\"}}}\n"
            try handle.seekToEnd()
            let start = clock.now
            try handle.write(contentsOf: Data(delta.utf8))
            let shown = await waitFor { lastAssistantText(store)?.contains(marker) == true }
            let elapsed = clock.now - start
            #expect(shown)
            samples.append(millis(elapsed))

            let final = "{\"type\":\"assistant\",\"session_id\":\"s\",\"message\":{\"id\":\"mf\(n)\",\"content\":[{\"type\":\"text\",\"text\":\"final \(n)\"}]}}\n"
            try handle.write(contentsOf: Data(final.utf8))
            #expect(await waitFor { lastAssistantText(store) == "final \(n)" })
        }
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let worst = sorted.last ?? 0
        print(String(format: "PERF reply-latency p50=%.2f p95=%.2f max=%.2f ms", p50, p95, worst))
        #expect(p95 <= 50)
    }

    @Test func echoShowsThePendingRowSynchronously() async throws {
        let dir = NSTemporaryDirectory() + "latency-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ConversationStore(path: dir + "/out.jsonl")
        let clock = ContinuousClock()
        let start = clock.now
        store.echo("hello")
        let elapsed = millis(clock.now - start)
        #expect(store.pending.count == 1)
        print(String(format: "PERF echo=%.4f ms", elapsed))
        #expect(elapsed < 1)
    }
}
