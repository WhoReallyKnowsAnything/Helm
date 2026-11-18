import AppKit
import SwiftUI
import Testing
@testable import Helm

/// D-02 of phase 6: while the editor shows inside the shell, the origin tab stays mounted (hidden), never removed.
@MainActor
struct WorkflowShellEditorTests {
    final class Counts {
        var appear = 0
        var disappear = 0
        var created = 0
    }

    final class Holder: ObservableObject {
        init(_ counts: Counts) { counts.created += 1 }
    }

    final class Toggle: ObservableObject {
        @Published var editorOn = false
    }

    struct Probe: View {
        let counts: Counts
        @StateObject private var holder: Holder
        init(counts: Counts) {
            self.counts = counts
            _holder = StateObject(wrappedValue: Holder(counts))
        }
        var body: some View {
            Color.blue.frame(height: 400).onAppear { counts.appear += 1 }.onDisappear { counts.disappear += 1 }
        }
    }

    struct Host: View {
        let counts: Counts
        @ObservedObject var toggle: Toggle
        var body: some View {
            WorkflowShellFrame(phases: [KitPhaseOption(id: "1", name: "One")], phase: "1", tab: "board",
                               editor: toggle.editorOn ? AnyView(Color.red) : nil) {
                Probe(counts: counts)
            }
        }
    }

    /// Shows the editor, then removes it, with a real window so `onAppear` fires.
    private func roundTrip(_ counts: Counts) async throws -> (appear: Int, disappear: Int, created: Int) {
        let toggle = Toggle()
        let host = NSHostingView(rootView: Host(counts: counts, toggle: toggle))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        toggle.editorOn = true
        try await Task.sleep(for: .milliseconds(300))
        #expect(counts.disappear == 0, "the tab was removed while the editor showed")
        toggle.editorOn = false
        try await Task.sleep(for: .milliseconds(300))
        // Read before the window goes away: tearing the window down fires onDisappear by itself.
        let snapshot = (appear: counts.appear, disappear: counts.disappear, created: counts.created)
        window.contentView = nil
        return snapshot
    }

    @Test func theOriginTabIsNotRemovedWhileTheEditorShows() async throws {
        let result = try await roundTrip(Counts())
        #expect(result.appear == 1)
        #expect(result.disappear == 0)
    }

    @Test func aStateObjectInTheTabKeepsItsInstanceAcrossTheRoundTrip() async throws {
        let result = try await roundTrip(Counts())
        #expect(result.created == 1)
    }
}
