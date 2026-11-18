import Foundation

/// Follows one out log and publishes its open permission requests (D-07). Reads from byte 0 on creation, then again
/// on every file event in the log's folder. No timer. Modelled on `ConversationStore`, with its own reader.
@MainActor
final class ControlLogStore: ObservableObject {
    @Published private(set) var pending: [PermissionRequest] = []
    /// The session's model and interrupt state, folded from the same line stream (D-09). Never written to disk (D-10).
    @Published private(set) var control = SessionControl()

    /// Touched only on `queue`.
    private final class Source: @unchecked Sendable {
        let reader: OutLogReader
        var fold = ControlRequests()
        var control = SessionControl()
        init(path: String) { reader = OutLogReader(path: path) }

        /// The folded state after one read, or nil when nothing changed.
        func poll() -> (pending: [PermissionRequest], control: SessionControl)? {
            let read = reader.read()
            if read.reset { fold = ControlRequests(); control = SessionControl() }
            guard read.reset || !read.lines.isEmpty else { return nil }
            fold.feed(read.lines)
            control.feed(read.lines)
            return (fold.pending, control)
        }
    }

    private let source: Source
    private let queue = DispatchQueue(label: "ControlLogStore.read")
    private let path: String
    private var watcher: ProjectWatcher?
    private var logSource: DispatchSourceFileSystemObject?
    private var reading = false
    private var readAgain = false

    init(path: String) {
        self.path = path
        source = Source(path: path)
        let folder = (path as NSString).deletingLastPathComponent
        var isFolder: ObjCBool = false
        // A missing folder gets no watcher and publishes nothing.
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { return }
        watcher = ProjectWatcher(folder: folder) { [weak self] in
            Task { @MainActor in
                self?.watchLog()
                self?.requestRead()
            }
        }
        watchLog()
        requestRead()
    }

    deinit { logSource?.cancel() }

    /// FSEvents sends nothing for appends through a write handle the writer holds open, so watch the file itself.
    private func watchLog() {
        guard logSource == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let log = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        log.setEventHandler { [weak self, weak log] in
            MainActor.assumeIsolated {
                guard let self, let log else { return }
                if !log.data.isDisjoint(with: [.delete, .rename]) {
                    log.cancel()
                    self.logSource = nil
                    self.watchLog()
                }
                self.requestRead()
            }
        }
        log.setCancelHandler { close(fd) }
        logSource = log
        log.resume()
    }

    private func requestRead() {
        if reading {
            readAgain = true
            return
        }
        reading = true
        let source = source
        queue.async { [weak self] in
            let folded = source.poll()
            Task { @MainActor in self?.finish(folded) }
        }
    }

    /// Marks an interrupt as sending. Call before the interrupt line is appended, so a fast response is not missed.
    func noteInterrupt(id: String) {
        let source = source
        let next = queue.sync { () -> SessionControl in
            source.control.noteInterrupt(id: id)
            return source.control
        }
        if control != next { control = next }
    }

    private func finish(_ folded: (pending: [PermissionRequest], control: SessionControl)?) {
        reading = false
        if let folded {
            if pending != folded.pending { pending = folded.pending }
            if control != folded.control { control = folded.control }
        }
        if readAgain {
            readAgain = false
            requestRead()
        }
    }
}
