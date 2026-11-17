import Foundation

/// The tabs of the workflow area (D-01), the default picked phase and the header words. A pure type with no UI imports.
/// The ids match `WorkflowShellFrame`'s tab ids.
enum WorkflowTabs {
    struct Tab: Equatable {
        let id: String
        let title: String
    }

    /// The five tabs that follow the picked phase.
    static let phaseTabs: [Tab] = ["Board", "Context", "Plan", "Execute", "Verify"].map { Tab(id: $0.lowercased(), title: $0) }
    /// The two project tabs, set apart at the right end.
    static let projectTabs: [Tab] = [Tab(id: "run", title: "Run Record"), Tab(id: "milestone", title: "Milestone")]
    static var all: [Tab] { phaseTabs + projectTabs }

    /// The cursor phase, else the first phase row, else nil. The phase text stays a string ("1.1", never "1.1.0").
    static func defaultPhase(status: CadenceStatus?, rows: [WorkflowBoard.Row]) -> String? {
        status?.current ?? rows.first?.n
    }

    /// Why there is no phase picker, or nil when there is one.
    static func noPickerReason(rows: [WorkflowBoard.Row]) -> String? {
        rows.isEmpty ? "This project has no phases yet." : nil
    }

    /// The line that names the picked phase and the tab.
    static func header(phase: String, rows: [WorkflowBoard.Row], tab: String) -> String {
        let name = rows.first { $0.n == phase }?.name ?? ""
        let title = all.first { $0.id == tab }?.title ?? tab
        return "Phase \(phase)  \(name)  /  \(title)"
    }
}
