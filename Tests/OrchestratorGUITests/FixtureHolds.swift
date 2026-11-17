import CryptoKit
import Foundation
@testable import OrchestratorGUI

/// Writes gate holds into a `FixtureProject`, in the shape `gate_hold_pending_write` writes them. A live hook is a
/// spawned `/bin/sleep 600` with its real `ps` start time on line 6. A dead hook is the PID of a child that has exited.
/// Call `remove()` to end the sleepers.
final class FixtureHolds {
    enum Hook { case live, dead }

    let project: FixtureProject
    private var sleepers: [Process] = []

    init(_ project: FixtureProject) { self.project = project }

    var folder: String { GateHoldReader.folder(of: project.path) }

    /// Writes `<id>.pending` and returns the hash of the op text. `decision` maps the hash to the `.decision` content.
    /// `altered` writes that op text while the hash stays the one of the real command (a tampered hold).
    @discardableResult
    func add(
        id: String, label: String = "bravo", tool: String = "Bash", command: String = "git push origin main",
        epoch: String = "100", hook: Hook = .live, decision: ((String) -> String)? = nil, altered: String? = nil
    ) throws -> String {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let op = Data("\(tool): \(command)".utf8)
        let hash = SHA256.hash(data: op).map { String(format: "%02x", $0) }.joined()
        let (pid, started) = try spawn(hook)
        let header = [label, hash, String(pid), epoch, project.path, started].map { $0 + "\n" }.joined()
        try (Data(header.utf8) + (altered.map { Data($0.utf8) } ?? op)).write(to: URL(fileURLWithPath: folder + "/\(id).pending"))
        if let decision { try decision(hash).write(toFile: folder + "/\(id).decision", atomically: false, encoding: .utf8) }
        return hash
    }

    func remove() {
        for sleeper in sleepers where sleeper.isRunning {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }
        sleepers = []
        project.remove()
    }

    private func spawn(_ hook: Hook) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hook == .live ? "/bin/sleep" : "/usr/bin/true")
        if hook == .live { process.arguments = ["600"] }
        try process.run()
        guard hook == .live else {
            process.waitUntilExit()
            return (process.processIdentifier, "Thu Jan  1 00:00:00 2026")
        }
        sleepers.append(process)
        let result = ProcessRunner.run(
            "/bin/ps", ["-o", "lstart=", "-p", String(process.processIdentifier)],
            environment: ["LC_ALL": "C", "TZ": "UTC"], timeout: 5)
        let started = result.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (process.processIdentifier, started)
    }
}
