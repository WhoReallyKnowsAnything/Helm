import SwiftUI

/// The main area while no project is selected.
struct EmptyStateView: View {
    var body: some View {
        KitNotice(text: "Select an orchestrator")
    }
}
