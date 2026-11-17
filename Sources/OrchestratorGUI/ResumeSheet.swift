import SwiftUI

/// What a node's `/resume` restarts (D-03): the root session or an orchestrator dashboard folder. A worker gets none.
enum ResumeTarget: Equatable {
    case root
    case folder(String)

    static func choose(root: Bool, worker: String?, folder: String?) -> ResumeTarget? {
        if root { return .root }
        guard worker == nil, let folder else { return nil }
        return .folder(folder)
    }

    /// Captures the environment and runs the launcher with the id, all off the main actor, as `RestoreModel.press` does.
    func relaunch(id: String) async throws {
        let target = self
        try await Task.detached {
            let envText = EnvironmentCapture.fileText(try EnvironmentCapture.capture())
            switch target {
            case .root: _ = try ProjectLauncher.launchRoot(envText: envText, resumeId: id)
            case .folder(let folder): _ = try ProjectLauncher.launch(folder: folder, envText: envText, resumeId: id)
            }
        }.value
    }
}

/// The `/resume` content (D-09): past conversations of the session folder, newest first. A pick relaunches the session.
struct ResumeSheet: View {
    let cwd: String
    let sessionId: String?
    let projects: String
    /// Nil for a session that cannot resume (a worker).
    let relaunch: (@MainActor (String) async throws -> Void)?
    @Binding var failure: String?
    @Binding var progress: String?
    let onDone: () -> Void
    /// Nil while the list loads; tests pass rows.
    @State var rows: [ResumeRow]?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.none) {
            if relaunch == nil {
                KitNotice(text: "Resume is not available for worker sessions.")
            } else if let rows, rows.isEmpty {
                KitNotice(text: "No past conversations for this folder.")
            } else if let rows {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(rows) { row($0) }
                    }
                }
                .frame(maxHeight: Metric.resumeListMaxHeight)
            }
        }
        .task { await load() }
    }

    private func row(_ row: ResumeRow) -> some View {
        HStack(spacing: Space.md) {
            Text(row.title).kitType(.body).foregroundStyle(Ink.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.isCurrent { Text("current").kitType(.meta).foregroundStyle(Ink.textSecondary) }
            Text(row.date.formatted(date: .abbreviated, time: .shortened)).kitType(.meta).foregroundStyle(Ink.muted)
            Button("Resume") { pick(row.id) }.buttonStyle(.kit).disabled(row.isCurrent || running)
        }
    }

    private func load() async {
        guard relaunch != nil, rows == nil else { return }
        progress = "Loading past conversations"
        let cwd = cwd, id = sessionId, projects = projects
        rows = await Task.detached { ResumeList.rows(cwd: cwd, currentId: id, projects: projects) }.value
        progress = nil
    }

    private func pick(_ id: String) {
        guard let relaunch, !running else { return }
        running = true
        failure = nil
        progress = "Restarting the session"
        Task {
            defer { running = false; progress = nil }
            do {
                try await relaunch(id)
                onDone()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
