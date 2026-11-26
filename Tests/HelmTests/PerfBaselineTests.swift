import Combine
import Foundation
import Testing
@testable import Helm

@MainActor
struct PerfBaselineTests {
    private let lineCount = 5_000

    private func lines(_ range: Range<Int>) -> String {
        range.map { i -> String in
            switch i % 4 {
            case 0: #"{"type":"user","isReplay":true,"session_id":"s","message":{"content":"question \#(i)"}}"#
            case 1: #"{"type":"assistant","session_id":"s","message":{"id":"m\#(i)","content":[{"type":"text","text":"answer \#(i)"}]}}"#
            case 2: #"{"type":"assistant","session_id":"s","message":{"id":"m\#(i)","content":[{"type":"tool_use","id":"t\#(i)","name":"Read","input":{"file":"f\#(i)"}}]}}"#
            default: #"{"type":"user","session_id":"s","message":{"content":[{"type":"tool_result","tool_use_id":"t\#(i - 1)","content":"done \#(i)","is_error":false}]}}"#
            }
        }.joined(separator: "\n") + "\n"
    }

    private func append(_ text: String, to path: String) throws {
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    private func wait(_ what: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !what(), ContinuousClock.now < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        return what()
    }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    @Test func openAndAppendBaseline() async throws {
        let dir = NSTemporaryDirectory() + "perf-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        try append(lines(0..<lineCount), to: out)

        let clock = ContinuousClock()
        let start = clock.now
        let store = ConversationStore(path: out)
        // 4-line cycle: user, text, tool_use paired with its result (one tool item).
        let expected = lineCount / 4 * 3
        let opened = await wait { store.items.count == expected }
        print("PERF open lines=\(lineCount) items=\(store.items.count) ms=\(ms(clock.now - start))")
        #expect(opened)

        var total = 0.0
        let appends = 20
        for n in 0..<appends {
            let before = store.items.count
            let t = clock.now
            try append(lines((lineCount + n * 4)..<(lineCount + n * 4 + 1)), to: out)
            #expect(await wait { store.items.count > before })
            total += ms(clock.now - t)
        }
        print("PERF append avgMs=\(total / Double(appends)) n=\(appends)")
    }

    @Test func refreshBaseline() async {
        let listed = TmuxOutcome.listed(sessions: "a\t\n", windows: "a\tmain\t/tmp\t%1\n")
        let store = SessionStore(runner: { listed })
        var emissions = 0
        let sink = store.$snapshot.sink { _ in emissions += 1 }
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<10 { await store.refresh() }
        print("PERF refresh x10 ms=\(ms(clock.now - start)) snapshotEmissions=\(emissions)")
        sink.cancel()
        #expect(store.tick == 10)
    }

    @Test func realLogBaseline() async throws {
        guard let source = ProcessInfo.processInfo.environment["PERF_OUTLOG"] else { return }
        let dir = NSTemporaryDirectory() + "perf-real-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/out.jsonl"
        try FileManager.default.copyItem(atPath: source, toPath: out)
        let data = try Data(contentsOf: URL(fileURLWithPath: out))
        let text = String(decoding: data, as: UTF8.self)
        print("PERF real lines=\(data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }) bytes=\(data.count)")

        let clock = ContinuousClock()
        let start = clock.now
        let store = ConversationStore(path: out)
        var last = store.items
        var lastChange = clock.now
        var firstItems: Double?
        while clock.now - start < .seconds(60), clock.now - lastChange < .milliseconds(300) {
            try? await Task.sleep(nanoseconds: 1_000_000)
            if store.items != last {
                last = store.items
                lastChange = clock.now
                if firstItems == nil, !last.isEmpty { firstItems = ms(clock.now - start) }
            }
        }
        print("PERF real open items=\(store.items.count) firstItemsMs=\(firstItems ?? -1) stableMs=\(ms(lastChange - start))")

        let scroll = TranscriptTextView.makeScrollView()
        let coordinator = TranscriptTextView.Coordinator()
        let renderStart = clock.now
        TranscriptTextView.render(scroll, coordinator: coordinator, items: store.items, accent: Ink.accent, expanded: [])
        print("PERF real render ms=\(ms(clock.now - renderStart))")

        let tail = text.split(separator: "\n").suffix(4).joined(separator: "\n") + "\n"
        let appends = 20
        var changeTotal = 0.0
        var renderTotal = 0.0
        var changed = 0
        for _ in 0..<appends {
            let before = store.items
            let t = clock.now
            try append(tail, to: out)
            let deadline = clock.now + .seconds(5)
            while store.items == before, clock.now < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
            guard store.items != before else { continue }
            changed += 1
            changeTotal += ms(clock.now - t)
            let r = clock.now
            TranscriptTextView.render(scroll, coordinator: coordinator, items: store.items, accent: Ink.accent, expanded: [])
            renderTotal += ms(clock.now - r)
        }
        print("PERF real append avgChangeMs=\(changeTotal / Double(max(changed, 1))) avgRenderMs=\(renderTotal / Double(max(changed, 1))) changed=\(changed)/\(appends)")
    }
}
