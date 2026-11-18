import Foundation
import Testing
@testable import Helm

struct ProcessRunnerTests {
    private func sh(_ script: String, timeout: TimeInterval = 10) -> ProcessResult {
        ProcessRunner.run("/bin/sh", ["-c", script], environment: ["PATH": "/usr/bin:/bin"], timeout: timeout)
    }

    @Test func keepsStdoutAndStderrApartAndReturnsTheStatus() {
        let result = sh("echo out; echo err >&2; exit 3")
        #expect(result.status == 3)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(!result.timedOut)
        #expect(!result.failedToStart)
    }

    @Test func passesOnlyTheGivenEnvironment() {
        let result = ProcessRunner.run("/usr/bin/env", [], environment: ["ONLY_ONE": "1"], timeout: 10)
        #expect(result.stdout == "ONLY_ONE=1\n")
    }

    @Test func aFullSecondPipeDoesNotHang() {
        let result = sh("head -c 1500000 /dev/zero >&2; echo done", timeout: 20)
        #expect(result.status == 0)
        #expect(result.stdout == "done\n")
        #expect(result.stderr.utf8.count == 1_500_000)
    }

    @Test func timeoutStopsASleepingCommand() {
        let start = Date()
        let result = ProcessRunner.run("/bin/sleep", ["30"], environment: [:], timeout: 1)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func timeoutReturnsEvenWhenAGrandchildHoldsThePipes() {
        let start = Date()
        let result = sh("sleep 30 & sleep 30", timeout: 1)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func feedsInputToTheChildsStdin() {
        let cat = ProcessRunner.run("/bin/cat", [], environment: [:], input: "y\n", timeout: 10)
        #expect(cat.stdout == "y\n")
        let read = ProcessRunner.run(
            "/bin/sh", ["-c", "read x; echo got:$x"], environment: ["PATH": "/usr/bin:/bin"], input: "y\n", timeout: 10)
        #expect(read.stdout == "got:y\n")
    }

    @Test func aChildThatNeverReadsItsInputDoesNotKillTheApp() {
        let big = String(repeating: "x", count: 2_000_000)
        let result = ProcessRunner.run("/usr/bin/true", [], environment: [:], input: big, timeout: 10)
        #expect(result.status == 0)
    }

    @Test func mergedOutputKeepsTheChildsOrderAndIsFast() {
        let start = Date()
        let result = ProcessRunner.run(
            "/bin/sh", ["-c", "echo a; echo b >&2; echo c"], environment: ["PATH": "/usr/bin:/bin"],
            mergeStderr: true, timeout: 10)
        #expect(result.stdout == "a\nb\nc\n")
        #expect(result.stderr.isEmpty)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func aMissingPathFailsToStart() {
        let result = ProcessRunner.run("/nonexistent/tool", [], environment: [:], timeout: 1)
        #expect(result.failedToStart)
        #expect(result.status == -1)
    }
}
