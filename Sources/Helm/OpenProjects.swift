import Foundation

/// One project the user had open: the tmux session id, the sidebar title and the project folder.
struct OpenProject: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    let folder: String
}

/// The app-owned list of open projects (D-01). It survives a restart or a tmux stop, so the sidebar can
/// show a project that has no live session. Records come from the live listing; only `remove` forgets one.
@MainActor
final class OpenProjects: ObservableObject {
    @Published private(set) var records: [OpenProject]
    /// File writes attempted since init. Tests read it to prove an unchanged snapshot writes nothing.
    private(set) var writeCount = 0
    private let file: URL

    /// The window's list. `ContentView` builds `CloseModel` in a property initializer, so it reaches the store through this.
    static let shared = OpenProjects()

    nonisolated static var defaultFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/OrchestratorGUI/open-projects.json")
    }

    init(file: URL = OpenProjects.defaultFile) {
        self.file = file
        // shortcut: a corrupt file loads empty and is replaced on the next write, upgrade if records become costly to lose.
        records = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([OpenProject].self, from: $0) } ?? []
    }

    /// Records every non-root row that has a `dashboard` window with a folder. Writes only when the list changed.
    func record(_ snapshot: TmuxSnapshot) {
        var next = records
        for row in snapshot.rows where !row.isRootSession {
            let folder = snapshot.windows.first { $0.session == row.id && $0.name == "dashboard" }?.path ?? ""
            guard !folder.isEmpty else { continue }
            let project = OpenProject(id: row.id, title: row.title, folder: folder)
            if let index = next.firstIndex(where: { $0.id == row.id }) {
                next[index].title = row.title
            } else {
                next.append(project)
            }
        }
        guard next != records else { return }
        records = next
        save()
    }

    /// The records whose id is not among `live`, in first-seen order.
    func dormant(excluding live: [SessionRow]) -> [OpenProject] {
        let liveIds = Set(live.map(\.id))
        return records.filter { !liveIds.contains($0.id) }
    }

    func remove(_ id: String) { remove([id]) }

    /// Drops every listed id with one write. Writes nothing when no listed id is present.
    func remove(_ ids: [String]) {
        guard records.contains(where: { ids.contains($0.id) }) else { return }
        records.removeAll { ids.contains($0.id) }
        save()
    }

    /// A failed write keeps the in-memory list; the next change retries.
    private func save() {
        writeCount += 1
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: file, options: .atomic)
        } catch {
            NSLog("OpenProjects: could not write \(file.path): \(error.localizedDescription)")
        }
    }
}
