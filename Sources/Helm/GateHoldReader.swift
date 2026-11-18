import Foundation

enum GateHoldRead: Equatable {
    /// Oldest first. Empty when the folder does not exist.
    case holds([GateHold])
    /// The folder exists and cannot be read (for example EPERM). Never shown as "no holds".
    case failed(String)
}

/// Reads `<project>/.claude/gate-holds/` and nothing more (D-01). It never creates, renames, deletes or touches a file or the folder.
enum GateHoldReader {
    /// A hold file is a few hundred bytes. Anything bigger is not one, and the cap keeps a worker from filling memory.
    static let maxFileBytes = 1 << 20

    static func folder(of project: String) -> String { project + "/.claude/gate-holds" }

    static func read(
        project: String, isHookLive: (Int32, String) -> Bool = GateHoldReader.hookIsLive
    ) -> GateHoldRead {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder(of: project))
        } catch let error as NSError {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if error.code == NSFileReadNoSuchFileError || posix == Int(ENOENT) || posix == Int(ENOTDIR) { return .holds([]) }
            return .failed("The gate holds folder cannot be read: \(error.localizedDescription)")
        }
        let holds = names.filter { $0.hasSuffix(".pending") }
            .compactMap { readHold(project: project, id: String($0.dropLast(".pending".count)), isHookLive: isHookLive) }
        return .holds(holds.sorted(by: GateHold.isOrderedBefore))
    }

    /// One hold by id, or nil when its files are gone or fail the checks. Used again right before a click is answered.
    static func readHold(
        project: String, id: String, isHookLive: (Int32, String) -> Bool = GateHoldReader.hookIsLive
    ) -> GateHold? {
        let base = folder(of: project) + "/" + id
        guard let pending = readRegularFile(base + ".pending") else { return nil }
        return GateHold.parse(id: id, pending: pending, decision: readRegularFile(base + ".decision"), isHookLive: isHookLive)
    }

    /// The PID is alive and its `ps` start time equals the one the hook recorded (D-02), which also catches a reused PID.
    static func hookIsLive(pid: Int32, started: String) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        let result = ProcessRunner.run(
            "/bin/ps", ["-o", "lstart=", "-p", String(pid)],
            environment: ["LC_ALL": "C", "TZ": "UTC"], timeout: 5)
        guard result.status == 0, !result.timedOut else { return false }
        let now = result.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !now.isEmpty && now == started
    }

    /// Opens without following a symlink and without blocking on a pipe, then requires a regular file under the size cap.
    static func readRegularFile(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxFileBytes else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maxFileBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.count <= maxFileBytes ? data : nil
    }
}
