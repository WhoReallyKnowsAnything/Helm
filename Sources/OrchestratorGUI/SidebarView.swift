import SwiftUI

/// The sidebar column: the New project item, one row per project, then the usage panel and the
/// session-list failure. It holds no store, so a render test needs no tmux. The Close alerts stay on the host (ContentView).
struct SidebarView: View {
    let newProject: NewProjectView
    let rows: [SessionRow]
    /// Each project's share of the Dock badge. Above 0 shows the alert dot.
    let alertCounts: [String: Int]
    let selected: String?
    let usage: UsageState
    let now: Date
    let failure: String?
    let onSelect: (String) -> Void
    /// Persisted projects with no live session (D-04). They are drawn after the live rows and cannot be selected.
    var dormant: [OpenProject] = []
    var onRemove: (String) -> Void = { _ in }
    /// Asks the host to confirm removing every dormant row. The host owns the alert.
    var onRemoveAll: () -> Void = {}
    /// Pressing Restore on a dormant row (D-02). The view starts nothing itself.
    var restore: (OpenProject) -> Void = { _ in }
    /// The id of the project whose restore runs now; its button is disabled.
    var restoring: String? = nil
    /// The open chat's `Ctx: N%` line for the usage panel; nil on the tree (D-17).
    var contextText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.none) {
            newProject
                .overlay(alignment: .bottom) { Ink.border.frame(height: Metric.hairline) }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(rows) { row in
                        KitSidebarRow(title: row.title, id: row.id, needsAttention: (alertCounts[row.id] ?? 0) > 0,
                                      selected: row.id == selected) { onSelect(row.id) }
                    }
                    ForEach(dormant) { project in
                        KitDormantRow(title: project.title, id: project.id,
                                      restore: { restore(project) }, running: restoring == project.id)
                            .contextMenu {
                                Button("Remove from List") { onRemove(project.id) }
                                Button("Remove All Not Running…") { onRemoveAll() }
                            }
                    }
                    if rows.isEmpty && dormant.isEmpty { KitNote(text: "No orchestrators running") }
                }
                .padding(Space.sm)
            }
            UsagePanelView(usage: usage, now: now, contextText: contextText)
            if let failure { KitFooterLine { Text(failure) } }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ink.sidebar)
    }
}
