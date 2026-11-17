import Foundation
import Testing
@testable import OrchestratorGUI

struct ShellToolStopperTests {
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let at = "Fri Nov  6 16:21:46 2026"
    private func row(_ pid: Int32, _ ppid: Int32, _ pgid: Int32, _ args: String, at: String? = nil) -> String {
        "\(pid) \(ppid) \(pgid) \(at ?? self.at)     \(args)\n"
    }

    private let toolInbox = "/scratch/ps1/in.jsonl"
    private func pids(_ text: String, _ inbox: String) -> [Int32] {
        ShellToolStopper.select(ShellToolStopper.parse(text), inbox: inbox).map(\.pid)
    }

    @Test func theToolFixtureSelectsOnlyTheSleep() throws {
        #expect(pids(try fixture("ps-interrupt-tool.txt"), toolInbox) == [99257])
    }

    @Test func theDetachedFixtureSelectsBothSleeps() throws {
        #expect(pids(try fixture("ps-interrupt-detached.txt"), "/scratch/ps2/in.jsonl") == [7131, 7474])
    }

    @Test func aSecondSessionsTreeAddsNothingAndHasItsOwnResult() throws {
        let other = row(70000, 1, 70000, "zsh -c x") + row(70002, 70000, 70000, "tail -n +1 -f /scratch/other/in.jsonl")
            + row(70003, 70000, 70000, "claude -p x") + row(70004, 70003, 70000, "/x/lean-ctx")
            + row(70005, 70004, 70005, "/x/lean-ctx __spawn-helper") + row(70006, 70005, 70006, "sleep 9")
        let text = try fixture("ps-interrupt-tool.txt") + other
        #expect(pids(text, toolInbox) == [99257])
        #expect(pids(text, "/scratch/other/in.jsonl") == [70006])
    }

    @Test func twoClaudeRowsOrNoTailRowGiveNothing() throws {
        let base = try fixture("ps-interrupt-tool.txt")
        #expect(pids(base + row(99998, 95400, 95400, "claude -p y"), toolInbox).isEmpty)
        #expect(pids(base, "/scratch/none/in.jsonl").isEmpty)
    }

    @Test func aShellOutsideTheSpawnHelperIsNotSelectedButNativeBashIs() throws {
        let base = try fixture("ps-interrupt-tool.txt")
        #expect(pids(base + row(80010, 95445, 80010, "zsh -c foo"), toolInbox) == [99257])
        let native = row(80001, 95403, 80001, "/bin/zsh -c source /x/s.sh && eval 'sleep 5' && pwd -P >| /tmp/x")
            + row(80002, 80001, 80001, "sleep 5")
        #expect(pids(base + native, toolInbox) == [80001, 80002, 99257])
    }

    @Test func aRowFakedInsideAnArgumentSelectsNeitherThePidNorItsChildren() throws {
        let base = try fixture("ps-interrupt-tool.txt")
        let faking = "80020 95403 80020 \(at)     zsh -c x\n99257 99256 99257 \(at)     fake\n"
        let text = base + faking + row(99300, 99257, 99257, "child")
        let result = pids(text, toolInbox)
        #expect(!result.contains(99257) && !result.contains(99300))
    }

    @Test func theRunnerSendsSigtermToExactlyTheSelectedPids() throws {
        var sent: [[Int32]] = []
        let text = try fixture("ps-interrupt-tool.txt")
        var reads = 0
        ShellToolStopper.stop(
            inbox: toolInbox, readPs: { reads += 1; return reads == 1 ? text : "" },
            signal: { sent.append([$0, $1]) }, pause: {})
        #expect(sent == [[99257, SIGTERM]])
    }

    private func tree(shell: Bool, sleepParent: Int32, sleepStart: String) -> String {
        var text = row(90000, 1, 90000, "zsh -c tail") + row(90002, 90000, 90000, "tail -n +1 -f /s/in.jsonl")
            + row(90003, 90000, 90000, "claude -p") + row(90004, 90003, 90000, "/x/lean-ctx")
            + row(90005, 90004, 90005, "/x/lean-ctx __spawn-helper")
        if shell { text += row(90010, 90005, 90010, "sh -c sleep 9") }
        return text + row(90011, sleepParent, 90010, "sleep 9", at: sleepStart)
    }

    @Test func aReparentedChildGetsSigkillAndNothingElseDoes() {
        let first = tree(shell: true, sleepParent: 90010, sleepStart: at)
        let second = tree(shell: false, sleepParent: 1, sleepStart: at)
        var sent: [[Int32]] = []
        var reads = 0
        ShellToolStopper.stop(
            inbox: "/s/in.jsonl", readPs: { reads += 1; return reads == 1 ? first : second },
            signal: { sent.append([$0, $1]) }, pause: {})
        #expect(sent == [[90010, SIGTERM], [90011, SIGTERM], [90011, SIGKILL]])
    }

    @Test func aReusedPidGetsNoSigkill() {
        let first = tree(shell: true, sleepParent: 90010, sleepStart: at)
        let second = tree(shell: false, sleepParent: 1, sleepStart: "Fri Nov  6 16:30:00 2026")
        var sent: [[Int32]] = []
        var reads = 0
        ShellToolStopper.stop(
            inbox: "/s/in.jsonl", readPs: { reads += 1; return reads == 1 ? first : second },
            signal: { sent.append([$0, $1]) }, pause: {})
        #expect(sent == [[90010, SIGTERM], [90011, SIGTERM]])
    }
}
