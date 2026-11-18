import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Helm

@MainActor private enum BodyRuns { static var count = 0 }

/// UAT 5 to 7: real card views mounted in a hosting view, the store changed after the mount, the drawn bitmap compared.
/// No remount between the two snapshots, as in the running app.
@MainActor
struct CardRedrawTests {
    /// Observes the store the way `ContentView` does and draws the cards the way the hold bar or the tree does.
    private struct Host: View {
        @ObservedObject var store: RequestStore
        let tree: Bool

        var body: some View {
            let _ = BodyRuns.count += 1
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if tree {
                        RequestCards(entries: store.entries, card: store.card(for:),
                                     onAnswer: store.answer, question: QuestionBinding(store), stamp: store.stamp)
                    } else if let bar = ProjectHoldBar(holds: [], requests: store.entries, root: false) {
                        ProjectHoldBarView(
                            bar: bar,
                            card: { HoldStore.Card(command: $0.command, stateLine: nil, outcome: nil, showsButtons: false, enabled: false) },
                            onDecide: { _, _ in }, requestCard: store.card(for:),
                            onRequestAnswer: store.answer, questionBinding: QuestionBinding(store),
                            requestStamp: store.stamp)
                    }
                }
            }
            .padding(8)
            .frame(width: 700, height: 600, alignment: .topLeading)
            .background(Ink.background)
            .preferredColorScheme(.dark)
        }
    }

    private struct Mounted {
        let window: NSWindow
        let host: NSHostingView<Host>

        func snapshot() throws -> Data {
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            window.display()
            host.needsDisplay = true
            host.displayIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try #require(rep.tiffRepresentation)
        }
    }

    private func mount(_ store: RequestStore, tree: Bool) -> Mounted {
        let host = NSHostingView(rootView: Host(store: store, tree: tree))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        // Ordered in so SwiftUI runs its update pass after a store change, but parked far offscreen.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return Mounted(window: window, host: host)
    }

    private func settle(_ seconds: Double = 0.4) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func session(_ fixture: String) throws -> (dir: String, session: RequestStore.Session) {
        let dir = NSTemporaryDirectory() + "gui-test-redraw-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lines = try ConversationFixtures.lines(fixture)
        let log = try #require(lines.first { $0.contains("control_request") }) + "\n"
        let out = dir + "/a.out.jsonl", inbox = dir + "/a.in.jsonl"
        FileManager.default.createFile(atPath: out, contents: Data(log.utf8))
        FileManager.default.createFile(atPath: inbox, contents: nil)
        return (dir, .init(nodeKey: "a", outPath: out, inboxPath: inbox, live: true))
    }

    private func store(_ fixture: String) async throws -> (dir: String, store: RequestStore, entry: RequestStore.Entry) {
        let s = try session(fixture)
        let store = RequestStore()
        store.setSessions([s.session])
        for _ in 0..<100 where store.entries.count != 1 { try await Task.sleep(nanoseconds: 50_000_000) }
        return (s.dir, store, try #require(store.entries.first))
    }

    private final class Counter: ObservableObject { @Published var n = 0 }
    private struct CounterView: View {
        @ObservedObject var counter: Counter
        var body: some View {
            VStack {
                Text(String(repeating: "W", count: 5 + counter.n * 10))
                Button { } label: { Text(String(repeating: "B", count: 5 + counter.n * 10)) }.buttonStyle(.kitPrompt)
            }.frame(width: 700, height: 600)
        }
    }

    /// Control: proves the harness sees a redraw at all, so a red card test names the card and not the harness.
    @Test func controlTheHarnessSeesAnObservedChange() async throws {
        let counter = Counter()
        let host = NSHostingView(rootView: CounterView(counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        func snap() throws -> Data {
            host.layoutSubtreeIfNeeded(); CATransaction.flush(); window.display()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try #require(rep.tiffRepresentation)
        }
        try await settle()
        let before = try snap()
        counter.n = 3
        try await settle()
        #expect(try snap() != before)
    }

    /// (a) A permission card mounted for a live request draws Allow enabled at once, and a later redraw matches a fresh mount.
    @Test func aMountedPermissionCardMatchesAFreshMountWithAllowEnabled() async throws {
        let s = try await store("can-use-tool-allow")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        for tree in [false, true] {
            let fresh = RequestStore()
            fresh.setSessions([try session("can-use-tool-allow").session])
            for _ in 0..<100 where fresh.entries.count != 1 { try await Task.sleep(nanoseconds: 50_000_000) }
            let entry = try #require(fresh.entries.first)
            let mounted = mount(fresh, tree: tree)
            try await settle()
            #expect(fresh.card(for: entry).enabled)
            let remounted = mount(fresh, tree: tree)
            try await settle(1.5)
            #expect(try mounted.snapshot() == remounted.snapshot(), "the mounted card differs from a fresh mount (tree: \(tree))")
        }
    }

    /// (b) A pick changes the drawn card with no remount.
    @Test func aQuestionCardChangesAfterAPick() async throws {
        let s = try await store("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let question = try #require(s.store.questions(for: s.entry).first)
        let mounted = mount(s.store, tree: false)
        try await settle()
        let before = try mounted.snapshot()
        let runsBefore = BodyRuns.count
        s.store.pick(s.entry.key, question: question.text, label: question.options[0].label)
        try await settle()
        #expect(BodyRuns.count > runsBefore, "Host.body did not re-run after the pick (runs \(runsBefore) -> \(BodyRuns.count))")
        let remounted = mount(s.store, tree: false)
        try await settle()
        let stale = try mounted.snapshot(), fresh = try remounted.snapshot()
        #expect(fresh != before, "even a fresh mount draws the same after the pick: the picture has no pick marker")
        #expect(stale == fresh, "the mounted card differs from a fresh mount of the same store")
    }

    /// (c) Pick A then pick B on a single-select question: only B is marked, and the picture is the one of a fresh pick of B.
    @Test func aSecondPickReplacesTheFirstInASingleSelectQuestion() async throws {
        let s = try await store("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let question = try #require(s.store.questions(for: s.entry).first { !$0.multiSelect && $0.options.count > 1 })
        let a = question.options[0].label, b = question.options[1].label
        let mounted = mount(s.store, tree: false)
        try await settle()
        s.store.pick(s.entry.key, question: question.text, label: a)
        try await settle()
        s.store.pick(s.entry.key, question: question.text, label: b)
        try await settle()
        #expect(s.store.picks(for: s.entry.key)[question.text] == [b])
        let again = try await store("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: again.dir) }
        again.store.pick(again.entry.key, question: question.text, label: b)
        let fresh = mount(again.store, tree: false)
        try await settle()
        #expect(try mounted.snapshot() == fresh.snapshot())
    }

    /// (d) One pick shows in the hold-bar host and the tree host alike.
    @Test func onePickShowsInTheBarAndTheTreeAlike() async throws {
        let s = try await store("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let question = try #require(s.store.questions(for: s.entry).first)
        let bar = mount(s.store, tree: false), tree = mount(s.store, tree: true)
        try await settle()
        let barBefore = try bar.snapshot(), treeBefore = try tree.snapshot()
        s.store.pick(s.entry.key, question: question.text, label: question.options[0].label)
        try await settle()
        #expect(try bar.snapshot() != barBefore, "the hold bar did not redraw")
        #expect(try tree.snapshot() != treeBefore, "the tree host did not redraw")
    }

    /// A highlight move from the keyboard shows in the bar and the tree alike.
    @Test func aHighlightMoveShowsInTheBarAndTheTreeAlike() async throws {
        let s = try await store("ask-user-question")
        defer { try? FileManager.default.removeItem(atPath: s.dir) }
        let bar = mount(s.store, tree: false), tree = mount(s.store, tree: true)
        try await settle()
        let barBefore = try bar.snapshot(), treeBefore = try tree.snapshot()
        #expect(s.store.handle(.init(key: .down), for: s.entry.key))
        try await settle()
        #expect(try bar.snapshot() != barBefore, "the hold bar did not redraw the highlight")
        #expect(try tree.snapshot() != treeBefore, "the tree host did not redraw the highlight")
    }
}
