import Foundation

struct ProcessResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    /// Set when the executable is missing or cannot be started; `status` is -1 then.
    var startError: String?

    var failedToStart: Bool { startError != nil }
}

/// Keeps what a reader thread has read so far, so a timeout can still return the partial output.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Runs one external command. The environment is always explicit: D-08 keeps the bare app environment
/// out of every session. Blocks by design (like `TmuxRunner.run`); callers run it off the main actor.
enum ProcessRunner {
    /// After the child exits, or is killed, wait this long for the pipes: a grandchild can hold them open for ever.
    private static let pipeDrainSeconds: TimeInterval = 1
    private static let killGraceSeconds: TimeInterval = 1

    static func run(
        _ executable: String, _ arguments: [String], environment: [String: String],
        workingFolder: String? = nil, input: String? = nil, mergeStderr: Bool = false, timeout: TimeInterval
    ) -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return ProcessResult(status: -1, stdout: "", stderr: "", startError: "not an executable file: \(executable)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let workingFolder { process.currentDirectoryURL = URL(fileURLWithPath: workingFolder) }
        let inPipe = input == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        // Merged: both streams share one pipe, so the caller gets them in the order the child wrote them.
        process.standardError = mergeStderr ? out : err
        do { try process.run() } catch {
            return ProcessResult(status: -1, stdout: "", stderr: "", startError: "\(executable) did not start: \(error)")
        }
        if let inPipe, let input {
            // Close our copy of the child's read end, so a child that exits unread turns the write into EPIPE.
            try? inPipe.fileHandleForReading.close()
            let writer = inPipe.fileHandleForWriting
            // EPIPE must come back as an error code, not kill the app with SIGPIPE.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            Thread.detachNewThread {
                let bytes = Array(input.utf8)
                var offset = 0
                while offset < bytes.count {
                    let n = bytes[offset...].withUnsafeBytes { write(writer.fileDescriptor, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    offset += n
                }
                try? writer.close()
            }
        }

        // Plain threads, not the global dispatch queue: callers block on that queue, and a starved pool would
        // leave these readers unscheduled, which shows up as empty output.
        let exited = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            process.waitUntilExit()
            exited.signal()
        }
        // Both pipes are read at the same time, so a full second pipe cannot stall the child.
        let readers = DispatchGroup()
        let outBuffer = OutputBuffer(), errBuffer = OutputBuffer()
        // Merged output has no reader on the unused stderr pipe: it would only add the drain wait.
        for (pipe, buffer) in mergeStderr ? [(out, outBuffer)] : [(out, outBuffer), (err, errBuffer)] {
            readers.enter()
            Thread.detachNewThread {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                readers.leave()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            // An interactive bash ignores SIGTERM.
            if exited.wait(timeout: .now() + killGraceSeconds) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + killGraceSeconds)
            }
        }
        _ = readers.wait(timeout: .now() + pipeDrainSeconds)
        return ProcessResult(
            status: process.isRunning ? -1 : process.terminationStatus,
            stdout: outBuffer.text, stderr: errBuffer.text, timedOut: timedOut)
    }
}
