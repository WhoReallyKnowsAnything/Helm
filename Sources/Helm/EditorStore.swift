import AppKit
import Foundation

/// The editor screen's data: the load result of the open file and its editable buffer. A load runs on `point`, off the
/// main actor, and a result is published only when it differs from the one shown. The store writes only the file it opened.
@MainActor
final class EditorStore: ObservableObject {
    @Published private(set) var result: EditorTextResult?
    /// The text now in the editor. Equals the baseline until the user edits.
    @Published private(set) var buffer = ""
    @Published private(set) var isDirty = false
    @Published private(set) var access: EditorAccess = .editable
    @Published private(set) var saveFailure: String?
    /// An unsaved draft from an earlier session that differs from the disk text. Nil until the user picks Restore or Discard.
    @Published private(set) var pendingDraft: String?
    /// D-06: the header toggle. The diff is of the saved file, so the buffer, the dirty state and the draft ignore it.
    @Published private(set) var showsDiff = false
    /// Nil while the reader runs or when the toggle is off.
    @Published private(set) var diff: EditorDiff.Outcome?
    /// The file changed on disk while the buffer had unsaved edits. Save does nothing until Reload or Keep mine.
    @Published private(set) var changedOnDisk = false

    private let loader: @Sendable (URL) -> EditorTextResult
    private let writer: @Sendable (String, URL, EditorAccess) -> EditorSave.Outcome
    private let queue = DispatchQueue(label: "EditorStore.read")
    /// Git can take up to 10 seconds, so the diff has its own queue and never holds up a load or a save.
    private let diffQueue = DispatchQueue(label: "EditorStore.diff")
    private let diffReader: @Sendable (URL) -> EditorDiff.Outcome
    private let watcherFactory: @Sendable (URL, @escaping @Sendable () -> Void) -> AnyObject?
    private var watcher: AnyObject?
    private var diffGeneration = 0
    private var url: URL?
    private var project: URL?
    private var rows: [WorkerRow] = []
    private var baseline = ""
    private var generation = 0
    private let drafts: EditorDrafts
    private let draftDelay: Duration
    private var draftTask: Task<Void, Never>?
    nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?

    init(loader: @escaping @Sendable (URL) -> EditorTextResult = { EditorText.load($0) },
         writer: @escaping @Sendable (String, URL, EditorAccess) -> EditorSave.Outcome = { EditorSave.write($0, to: $1, access: $2) },
         drafts: EditorDrafts = EditorDrafts(),
         draftDelay: Duration = .seconds(1),
         diffReader: @escaping @Sendable (URL) -> EditorDiff.Outcome = { EditorDiff.read($0) },
         watcherFactory: @escaping @Sendable (URL, @escaping @Sendable () -> Void) -> AnyObject? = {
             ProjectWatcher(file: $0.path, onEvent: $1)
         }) {
        self.loader = loader
        self.watcherFactory = watcherFactory
        self.diffReader = diffReader
        self.writer = writer
        self.drafts = drafts
        self.draftDelay = draftDelay
        // No queue, so the flush runs on the posting (main) thread before the app exits.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    /// The real path that names the draft. Nil when no file is open.
    private var draftKey: String? {
        url?.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func point(at url: URL?) {
        guard url != self.url else { return }
        self.url = url
        diff = nil
        watcher = url.flatMap { file in
            watcherFactory(file) { [weak self] in Task { @MainActor in self?.diskChanged() } }
        }
        loadDiff()
        reload()
    }

    /// An outside write to the open file: re-read it off the main actor. Text equal to the baseline changes nothing, which
    /// covers the store's own save.
    private func diskChanged() {
        guard let url else { return }
        let loader = loader
        queue.async { [weak self] in
            let loaded = loader(url)
            Task { @MainActor in self?.applyDisk(loaded, for: url) }
        }
    }

    private func applyDisk(_ loaded: EditorTextResult, for read: URL) {
        guard read == url else { return }
        if case .text(let text) = loaded {
            guard text != baseline else { return }
            if isDirty { changedOnDisk = true; return }
            result = loaded
            baseline = text
            buffer = text
            updatePending()
            loadDiff()
        } else if loaded != result {
            result = loaded
            if !isDirty { baseline = ""; buffer = "" }
        }
    }

    /// Reload: the disk text becomes the buffer and the baseline, and the draft goes.
    func reloadFromDisk() {
        guard let url else { return }
        let loader = loader
        queue.async { [weak self] in
            let loaded = loader(url)
            Task { @MainActor in self?.adoptDisk(loaded, for: url) }
        }
    }

    private func adoptDisk(_ loaded: EditorTextResult, for read: URL) {
        guard read == url else { return }
        result = loaded
        if case .text(let text) = loaded { baseline = text; buffer = text } else { baseline = ""; buffer = "" }
        isDirty = false
        changedOnDisk = false
        saveFailure = nil
        draftTask?.cancel()
        if let key = draftKey { drafts.remove(key) }
        updatePending()
        loadDiff()
    }

    /// Keep mine: the buffer stays, and the next save overwrites the disk text.
    func keepMine() { changedOnDisk = false }

    func toggleDiff() {
        showsDiff.toggle()
        if showsDiff { loadDiff() } else { diffGeneration += 1; diff = nil }
    }

    /// Reads the diff off the main actor. A result from an older call, or after the toggle went off, is dropped.
    private func loadDiff() {
        guard showsDiff, let url else { return }
        diffGeneration += 1
        let current = diffGeneration
        let reader = diffReader
        diffQueue.async { [weak self] in
            let outcome = reader(url)
            Task { @MainActor in
                guard let self, self.showsDiff, current == self.diffGeneration else { return }
                self.diff = outcome
            }
        }
    }

    /// The project folder and the worker rows that decide whether the file is read-only.
    func configure(project: URL?, rows: [WorkerRow]) {
        guard project != self.project || rows != self.rows else { return }
        self.project = project
        self.rows = rows
        updateAccess()
    }

    func reload() {
        generation += 1
        let current = generation
        guard let url else {
            result = nil
            return
        }
        let loader = loader
        queue.async { [weak self] in
            let loaded = loader(url)
            Task { @MainActor in self?.finish(loaded, generation: current) }
        }
    }

    /// A user edit. Ignored for a read-only file and before a text has loaded.
    func edit(_ text: String) {
        guard access.isEditable, case .text = result, text != buffer else { return }
        buffer = text
        isDirty = buffer != baseline
        scheduleDraft()
    }

    /// Writes the draft at once when the buffer is dirty. Call it when the screen goes away.
    func flush() {
        draftTask?.cancel()
        draftTask = nil
        writeDraft()
    }

    /// The buffer becomes the draft text exactly. The disk file is untouched.
    func restore() {
        guard let draft = pendingDraft, access.isEditable else { return }
        pendingDraft = nil
        buffer = draft
        isDirty = buffer != baseline
    }

    func discard() {
        pendingDraft = nil
        if let key = draftKey, access.isEditable { drafts.remove(key) }
    }

    private func scheduleDraft() {
        draftTask?.cancel()
        draftTask = nil
        guard isDirty else {
            if let key = draftKey { drafts.remove(key) }
            return
        }
        let delay = draftDelay
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.writeDraft()
        }
    }

    private func writeDraft() {
        guard isDirty, access.isEditable, let key = draftKey else { return }
        do { try drafts.write(buffer, for: key) } catch { NSLog("EditorStore: could not write a draft: \(error.localizedDescription)") }
    }

    /// An offer exists only for an editable, unedited file whose draft differs from the disk text.
    private func updatePending() {
        guard access.isEditable, !isDirty, case .text = result, let key = draftKey,
              let draft = drafts.read(key), draft != baseline else {
            pendingDraft = nil
            return
        }
        pendingDraft = draft
    }

    /// Writes the buffer to the open file off the main actor. On success the buffer becomes the baseline; on failure it stays.
    func save() {
        guard let url, access.isEditable, isDirty else { return }
        guard !changedOnDisk else {
            saveFailure = "the file changed on disk; pick Reload or Keep mine"
            return
        }
        let text = buffer
        let access = access
        let writer = writer
        let real = url.standardizedFileURL.resolvingSymlinksInPath()
        queue.async { [weak self] in
            let outcome = writer(text, real, access)
            Task { @MainActor in self?.finishSave(outcome, text: text) }
        }
    }

    private func finishSave(_ outcome: EditorSave.Outcome, text: String) {
        switch outcome {
        case .saved:
            baseline = text
            saveFailure = nil
            loadDiff()
            if buffer == baseline {
                draftTask?.cancel()
                if let key = draftKey { drafts.remove(key) }
            }
        case .failed(let reason):
            saveFailure = reason
        }
        isDirty = buffer != baseline
    }

    private func finish(_ loaded: EditorTextResult, generation done: Int) {
        guard done == generation, loaded != result else { return }
        result = loaded
        if case .text(let text) = loaded {
            baseline = text
            buffer = text
        } else {
            baseline = ""
            buffer = ""
        }
        isDirty = false
        saveFailure = nil
        changedOnDisk = false
        updateAccess()
    }

    private func updateAccess() {
        guard let url else { access = .editable; return }
        access = EditorAccess.resolve(url, project: project ?? URL(fileURLWithPath: "/"), rows: rows)
        updatePending()
    }
}
