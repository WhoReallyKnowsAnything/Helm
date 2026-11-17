import Foundation

/// One running project in the quit dialog. Unchecked keeps it running in tmux (PROJECT.md).
struct QuitEntry: Equatable, Identifiable {
    let id: String
    let title: String
    let folder: String
    var isChecked = false
}

struct QuitFailure: Equatable {
    let title: String
    let reason: String
}

/// The quit dialog's data and its stop step. The teardown arrives as a closure (Task 1 supplies the real one),
/// and this model makes no tmux call of its own.
@MainActor
final class QuitModel: ObservableObject {
    @Published private(set) var entries: [QuitEntry]
    private let teardown: @Sendable (_ sessionId: String, _ folder: String) async throws -> Void

    /// One entry per row of the snapshot, in row order. The folder is the row's `dashboard` window path.
    init(snapshot: TmuxSnapshot, teardown: @escaping @Sendable (String, String) async throws -> Void) {
        entries = snapshot.rows.map { row in
            let folder = snapshot.windows.first { $0.session == row.id && $0.name == "dashboard" }?.path ?? ""
            return QuitEntry(id: row.id, title: row.title, folder: folder)
        }
        self.teardown = teardown
    }

    func setChecked(_ id: String, _ isChecked: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isChecked = isChecked
    }

    /// Stops the checked entries one after another. A failure does not stop the rest.
    func confirm() async -> [QuitFailure] {
        var failures: [QuitFailure] = []
        for entry in entries where entry.isChecked {
            do { try await teardown(entry.id, entry.folder) } catch {
                failures.append(QuitFailure(title: entry.title, reason: error.localizedDescription))
            }
        }
        return failures
    }
}
