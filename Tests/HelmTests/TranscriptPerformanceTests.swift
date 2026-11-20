import AppKit
import Testing
@testable import Helm

@MainActor
struct TranscriptPerformanceTests {
    /// Each message has its own text, as a real transcript does, so nothing can lean on repeated text.
    private static func markdown(_ row: Int) -> String { (0..<8).map { n in
        """
        ## Section \(row)-\(n)
        Some **bold** and `code` text with a [link](https://example.com/\(n)) in a sentence.
        - first item \(n)
        - second item with *emphasis*
        - third item
        ```swift
        let value = \(n)
        ```
        """
    }.joined(separator: "\n") }

    static func transcript(rows: Int = 150) -> [ConversationItem] {
        var items: [ConversationItem] = []
        for i in 0..<rows - 1 {
            switch i % 3 {
            case 0: items.append(.user(id: "u\(i)", text: "question number \(i)"))
            case 1: items.append(.assistant(id: "a\(i)", text: markdown(i), inProgress: false))
            default: items.append(.tool(id: "t\(i)", name: "Read", input: .object(["file_path": .string("/tmp/f\(i)")]), result: ToolResult(text: "ok", isError: false)))
            }
        }
        items.append(.assistant(id: "last", text: markdown(rows), inProgress: true))
        return items
    }

    static func appendToLast(_ items: [ConversationItem], _ extra: String) -> [ConversationItem] {
        var next = items
        if case .assistant(let id, let text, let inProgress)? = next.last { next[next.count - 1] = .assistant(id: id, text: text + extra, inProgress: inProgress) }
        return next
    }

    static func scrollView() -> TranscriptScrollView {
        let scroll = TranscriptTextView.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        return scroll
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", "Absolute frame budget; the hosted runner measured p95 16.5 ms vs 16 (run 44623767497). Runs locally and in the export gate."))
    func streamingUpdatesStayWithinTheFrameBudget() {
        let scroll = Self.scrollView()
        let coordinator = TranscriptTextView.Coordinator()
        var items = Self.transcript()
        TranscriptTextView.render(scroll, coordinator: coordinator, items: items, accent: Ink.accent, expanded: [])
        var times: [Double] = []
        let clock = ContinuousClock()
        for n in 0..<300 {
            items = Self.appendToLast(items, " delta\(n) words..")
            let elapsed = clock.measure {
                TranscriptTextView.render(scroll, coordinator: coordinator, items: items, accent: Ink.accent, expanded: [])
            }
            times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        times.sort()
        let p95 = times[Int(Double(times.count) * 0.95) - 1]
        let worst = times[times.count - 1]
        print("PERF streaming p95=\(p95) max=\(worst)")
        #expect(p95 <= 16)
        #expect(worst <= 50)
    }

    /// Five opens of a 300-row transcript, slowest last. `cold` forgets parsed messages before each open.
    private func openTimes(cold: Bool) -> [Double] {
        let items = Self.transcript(rows: 300)
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<5 {
            if cold { TranscriptText.resetParseCache() }
            let scroll = Self.scrollView()
            let coordinator = TranscriptTextView.Coordinator()
            let elapsed = clock.measure {
                TranscriptTextView.render(scroll, coordinator: coordinator, items: items, accent: Ink.accent, expanded: [])
            }
            times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return times.sorted()
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", "Absolute time budget; the hosted runner is about 2x slower (open max 286 ms vs 200). Runs locally and in the export gate."))
    func firstOpenOfALongTranscriptStaysWithinBudget() {
        let cold = openTimes(cold: true)
        let warm = openTimes(cold: false)
        print("PERF open cold p50=\(cold[2]) max=\(cold[4]) ms, reopen p50=\(warm[2]) max=\(warm[4]) ms")
        // The macOS hang threshold is 250 ms. Release, 300 rows with distinct text: before cold 172 ms max; now cold 131, reopen 98.
        // Layout of the finished text (about 52 ms) is the rest and has to run before the view can scroll to the bottom.
        #if DEBUG
        #expect(cold[4] <= 200) // debug before: 257 ms max, now about 154
        #else
        #expect(cold[4] <= 150)
        #expect(warm[4] <= 110)
        #endif
    }

    @Test func incrementalRenderMatchesAFullBuild() {
        let scroll = Self.scrollView()
        let coordinator = TranscriptTextView.Coordinator()
        var items = Self.transcript(rows: 12)
        var expanded: Set<String> = []
        var generator = SystemRandomNumberGenerator()
        func check() {
            let storage = (scroll.documentView as! NSTextView).textStorage!
            let want = TranscriptText.build(items, accent: Ink.accent, expanded: expanded)
            #expect(storage.string == want.string)
            guard storage.length == want.length else { return }
            var mismatches = 0
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
                let other = want.attributes(at: range.location, effectiveRange: nil)
                let blocks = { (a: [NSAttributedString.Key: Any]) -> [NSColor?] in (a[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.map { ($0 as? RoundedTextBlock)?.fill } ?? [] }
                let same = Set(attrs.keys) == Set(other.keys) && blocks(attrs) == blocks(other)
                    && (attrs[.font] as? NSFont) == (other[.font] as? NSFont) && (attrs[.foregroundColor] as? NSColor) == (other[.foregroundColor] as? NSColor)
                    && (attrs[.link] as? URL) == (other[.link] as? URL)
                if !same { mismatches += 1 }
            }
            #expect(mismatches == 0)
        }
        TranscriptTextView.render(scroll, coordinator: coordinator, items: items, accent: Ink.accent, expanded: expanded)
        check()
        for step in 0..<40 {
            switch Int.random(in: 0..<5, using: &generator) {
            case 0: items = Self.appendToLast(items, "\n- more \(step)")
            case 1: items.append(.tool(id: "n\(step)", name: "Bash", input: .null, result: nil))
            case 2: items.append(.assistant(id: "n\(step)", text: "## h\(step)\ntext", inProgress: true))
            case 3:
                if let i = items.indices.first(where: { if case .tool = items[$0] { return true } else { return false } }), case .tool(let id, let name, let input, _) = items[i] {
                    items[i] = .tool(id: id, name: name, input: input, result: ToolResult(text: "done \(step)", isError: step % 2 == 0))
                }
            default: expanded.formSymmetricDifference([TranscriptText.runKey("t2")])
            }
            TranscriptTextView.render(scroll, coordinator: coordinator, items: items, accent: Ink.accent, expanded: expanded)
            check()
        }
        items.removeLast(3)
        TranscriptTextView.render(scroll, coordinator: coordinator, items: items, accent: Ink.accent, expanded: expanded)
        check()
    }
}
