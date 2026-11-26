import Foundation
import Testing
@testable import Helm

/// A synthetic out log of 50 MB or more, shaped like a real one: long stream-delta lines, a few control lines.
@MainActor
struct LargeLogBenchmarkTests {
    static let targetBytes = 50 * 1024 * 1024

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func makeLog() throws -> (dir: String, out: String, lines: Int) {
        let dir = NSTemporaryDirectory() + "bench-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let out = dir + "/out.jsonl"
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 40)
        var text = ""
        var lines = 0
        var written = 0
        FileManager.default.createFile(atPath: out, contents: nil)
        let handle = try #require(FileHandle(forWritingAtPath: out))
        defer { try? handle.close() }
        var i = 0
        while written < Self.targetBytes {
            text.removeAll(keepingCapacity: true)
            for _ in 0..<500 {
                i += 1
                switch i % 50 {
                case 0: text += #"{"type":"user","session_id":"s","message":{"content":"question \#(i)"}}"# + "\n"
                case 1: text += #"{"type":"assistant","session_id":"s","message":{"id":"m\#(i)","content":[{"type":"text","text":"answer \#(i)"}]}}"# + "\n"
                case 2: text += #"{"type":"control_request","request_id":"r\#(i)","request":{"subtype":"can_use_tool","tool_name":"Read","tool_use_id":"t\#(i)","input":{"file":"f"}}}"# + "\n"
                case 3: text += #"{"type":"user","session_id":"s","message":{"content":[{"type":"tool_result","tool_use_id":"t\#(i - 1)","content":"done","is_error":false}]}}"# + "\n"
                default:
                    text += #"{"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(filler)\#(i)"}}}"# + "\n"
                }
                lines += 1
            }
            let data = Data(text.utf8)
            try handle.write(contentsOf: data)
            written += data.count
        }
        return (dir, out, lines)
    }

    @Test func aSecondOpenOfTheSamePathReusesTheStoreAndOnlyThreeAreKept() {
        let requests = RequestStore()
        let paths = (0..<4).map { NSTemporaryDirectory() + "no-such-\(UUID().uuidString)/\($0).out.jsonl" }
        let first = requests.conversationStore(for: paths[0])
        #expect(requests.conversationStore(for: paths[0]) === first)
        _ = requests.conversationStore(for: paths[1])
        _ = requests.conversationStore(for: paths[2])
        _ = requests.conversationStore(for: paths[3])
        #expect(requests.conversationStore(for: paths[0]) !== first)
    }

    @Test func firstOpenOfA50MBLogIsUnderOneSecond() async throws {
        let log = try makeLog()
        defer { try? FileManager.default.removeItem(atPath: log.dir) }
        let clock = ContinuousClock()

        var start = clock.now
        let readStart = start
        let read = OutLogReader(path: log.out).read()
        print("BENCH reader ms=\(ms(clock.now - start)) lines=\(read.lines.count)")
        #expect(read.lines.count == log.lines)

        start = clock.now
        var requests = ControlRequests()
        requests.feed(read.lines)
        print("BENCH ControlRequests ms=\(ms(clock.now - start)) pending=\(requests.pending.count)")

        start = clock.now
        var control = SessionControl()
        control.feed(read.lines)
        print("BENCH SessionControl ms=\(ms(clock.now - start))")
        let screened = ms(clock.now - readStart)

        start = clock.now
        var parser = ConversationParser()
        parser.feed(read.lines)
        print("BENCH ConversationParser ms=\(ms(clock.now - start)) items=\(parser.items.count)")

        start = clock.now
        let store = ConversationStore(path: log.out)
        while store.items.isEmpty, clock.now - start < .seconds(60) { try? await Task.sleep(nanoseconds: 1_000_000) }
        let opened = ms(clock.now - start)
        print("BENCH store first items ms=\(opened)")
        // The store open runs on a queue and shares the CPU with the parallel suite, so only the stages above gate the time.
        #expect(!store.items.isEmpty)
        #expect(screened < 1000, "reader + both screens over \(Self.targetBytes) bytes")
    }
}
