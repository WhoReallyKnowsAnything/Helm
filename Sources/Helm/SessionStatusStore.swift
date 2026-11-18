import Foundation

/// Follows a set of out logs and publishes, per log path, the folded turn state and the file's modification time
/// (D-01, D-05). Keyed by path, never by label. No clock and no timer (D-10): the caller runs the stall check with a
/// fresh `now`. Modelled on `ConversationStore`.
@MainActor
final class SessionStatusStore: ObservableObject {
    struct Entry: Equatable {
        let fold: SessionStatusFold
        /// The log file's modification time, not an event timestamp (D-05).
        let modified: Date
    }

    /// A path whose file does not exist has no entry (D-08).
    @Published private(set) var entries: [String: Entry] = [:]

    /// Touched only on `queue`.
    private final class Source: @unchecked Sendable {
        let path: String
        let reader: OutLogReader
        var fold = SessionStatusFold()
        init(path: String) { self.path = path; reader = OutLogReader(path: path) }

        func poll() -> Entry? {
            let read = reader.read()
            if read.reset { fold = SessionStatusFold() }
            fold.feed(read.lines)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { return nil }
            return Entry(fold: fold, modified: modified)
        }
    }

    private let queue = DispatchQueue(label: "SessionStatusStore.read")
    private var sources: [String: Source] = [:]
    /// Per followed path; a result that carries another value is stale and dropped.
    private var generations: [String: Int] = [:]
    private var nextGeneration = 0
    private var reading: Set<String> = []
    private var readAgain: Set<String> = []
    private var watchers: [String: ProjectWatcher] = [:]
    private var logSources: [String: DispatchSourceFileSystemObject] = [:]

    deinit { logSources.values.forEach { $0.cancel() } }

    /// Runs again for an unchanged set: a folder or file that did not exist on an earlier call gets its watcher now.
    func follow(_ paths: Set<String>) {
        for path in sources.keys where !paths.contains(path) {
            sources[path] = nil
            generations[path] = nil
            reading.remove(path)
            readAgain.remove(path)
            logSources.removeValue(forKey: path)?.cancel()
            entries[path] = nil
        }
        let added = paths.filter { sources[$0] == nil }
        for path in added {
            sources[path] = Source(path: path)
            nextGeneration += 1
            generations[path] = nextGeneration
        }
        let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        for folder in watchers.keys where !folders.contains(folder) { watchers[folder] = nil }
        for folder in folders where watchers[folder] == nil {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { continue }
            watchers[folder] = ProjectWatcher(folder: folder) { [weak self] in
                Task { @MainActor in self?.folderChanged(folder) }
            }
        }
        for path in paths {
            let watchedBefore = logSources[path] != nil
            watchLog(path)
            if added.contains(path) || (!watchedBefore && logSources[path] != nil) { requestRead(path) }
        }
    }

    private func folderChanged(_ folder: String) {
        for path in sources.keys where (path as NSString).deletingLastPathComponent == folder {
            watchLog(path)
            requestRead(path)
        }
    }

    /// FSEvents sends nothing for appends through a write handle the writer holds open, so watch the file itself.
    private func watchLog(_ path: String) {
        guard sources[path] != nil, logSources[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let log = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        log.setEventHandler { [weak self, weak log] in
            MainActor.assumeIsolated {
                guard let self, let log else { return }
                if !log.data.isDisjoint(with: [.delete, .rename]) {
                    log.cancel()
                    self.logSources[path] = nil
                    self.watchLog(path)
                }
                self.requestRead(path)
            }
        }
        log.setCancelHandler { close(fd) }
        logSources[path] = log
        log.resume()
    }

    private func requestRead(_ path: String) {
        guard let source = sources[path], let generation = generations[path] else { return }
        if reading.contains(path) {
            readAgain.insert(path)
            return
        }
        reading.insert(path)
        queue.async { [weak self] in
            let entry = source.poll()
            Task { @MainActor in self?.finish(path, generation: generation, entry) }
        }
    }

    private func finish(_ path: String, generation: Int, _ entry: Entry?) {
        guard generations[path] == generation else { return }
        reading.remove(path)
        if entries[path] != entry { entries[path] = entry }
        if readAgain.remove(path) != nil { requestRead(path) }
    }
}
